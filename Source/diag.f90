! a generic diag module for MAESTRO.  This simply computes the 
! maximum Mach number on the domain and outputs it each timestep
! to maestro_diag.out

module diag_module

  use bl_types
  use bl_IO_module
  use multifab_module
  use ml_layout_module
  use define_bc_module

  implicit none

  private

  public :: diag, flush_diag

contains

  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine diag(time,dt,dx,s,rho_Hnuc,rho_Hext,thermal,rho_omegadot, &
                  rho0,rhoh0,p0,tempbar, &
                  gamma1bar,div_coeff, &
                  u,w0,normal, &
                  mla,the_bc_tower)

    use bl_prof_module
    use geometry, only: dm, nlevs, spherical
    use bl_constants_module
    use probin_module, only: prob_lo_x, prob_lo_y, prob_lo_z, &
                             prob_hi_x, prob_hi_y, prob_hi_z, &
                             job_name
    use network, only: network_species_index
    use inlet_bc_module
    use fill_3d_module, only: put_1d_array_on_cart, make_w0mac
    use variables, only: foextrap_comp

    real(kind=dp_t), intent(in   ) :: dt,dx(:,:),time
    type(multifab) , intent(in   ) :: s(:)
    type(multifab) , intent(in   ) :: rho_Hnuc(:)
    type(multifab) , intent(in   ) :: rho_Hext(:)
    type(multifab) , intent(in   ) :: thermal(:)
    type(multifab) , intent(in   ) :: rho_omegadot(:)
    type(multifab) , intent(in   ) :: u(:)
    type(multifab) , intent(in   ) :: normal(:)
    real(kind=dp_t), intent(in   ) ::      rho0(:,0:)
    real(kind=dp_t), intent(in   ) ::     rhoh0(:,0:)
    real(kind=dp_t), intent(in   ) ::        p0(:,0:)
    real(kind=dp_t), intent(in   ) ::   tempbar(:,0:)
    real(kind=dp_t), intent(in   ) :: gamma1bar(:,0:)
    real(kind=dp_t), intent(in   ) :: div_coeff(:,0:)
    real(kind=dp_t), intent(in   ) ::        w0(:,0:)
    type(ml_layout), intent(in   ) :: mla
    type(bc_tower) , intent(in   ) :: the_bc_tower

    ! Local
    real(kind=dp_t), pointer::  sp(:,:,:,:)
    real(kind=dp_t), pointer::  rhnp(:,:,:,:)
    real(kind=dp_t), pointer::  rhep(:,:,:,:)
    real(kind=dp_t), pointer::  rwp(:,:,:,:)
    real(kind=dp_t), pointer::  up(:,:,:,:)
    real(kind=dp_t), pointer :: np(:,:,:,:)
    real(kind=dp_t), pointer :: w0rp(:,:,:,:)
    real(kind=dp_t), pointer :: w0xp(:,:,:,:)
    real(kind=dp_t), pointer :: w0yp(:,:,:,:)
    real(kind=dp_t), pointer :: w0zp(:,:,:,:)
    logical        , pointer::  mp(:,:,:,:)

    type(multifab) :: w0r_cart(mla%nlevel)
    type(multifab) ::    w0mac(mla%nlevel,dm)

    real(kind=dp_t) :: Mach_max, Mach_max_level, Mach_max_local

    integer :: lo(dm),hi(dm)
    integer :: ng_s,ng_u,ng_n,ng_rhn,ng_rhe,ng_rw,ng_w,ng_wm
    integer :: i,n,comp
    integer :: un
    logical :: lexist

    logical, save :: firstCall_io = .true.

    type(bl_prof_timer), save :: bpt

    call build(bpt, "diagnostics")


    if (spherical .eq. 1) then

       do n=1,nlevs
          
          do comp=1,dm
             ! w0mac will contain an edge-centered w0 on a Cartesian
             ! grid, for use in computing divergences.
             call multifab_build_edge(w0mac(n,comp), mla%la(n),1,1,comp)
             call setval(w0mac(n,comp), ZERO, all=.true.)
          enddo

          ! w0r_cart is w0 but onto a Cartesian grid in cell-centered
          ! as a scalar.  Since w0 is the radial expansion velocity,
          ! w0r_cart is the radial w0 in a zone
          call multifab_build(w0r_cart(n), mla%la(n),1,0)
          call setval(w0r_cart(n), ZERO, all=.true.)
       end do

       ! put w0 on Cartesian edges as a vector
       call make_w0mac(mla,w0,w0mac,dx,the_bc_tower%bc_tower_array)


       ! put w0 in Cartesian cell-centers as a scalar (the radial
       ! expansion velocity)
       call put_1d_array_on_cart(w0,w0r_cart,foextrap_comp,.true.,.false.,dx, &
                                 the_bc_tower%bc_tower_array,mla)
    endif

    ng_s   = nghost(s(1))
    ng_u   = nghost(u(1))
    ng_n   = nghost(normal(1))
    ng_rhn = nghost(rho_Hnuc(1))
    ng_rhe = nghost(rho_Hext(1))
    ng_rw  = nghost(rho_omegadot(1))
    if (spherical == 1) then
       ng_n   = nghost(normal(1))
       ng_w   = nghost(w0r_cart(1))
       ng_wm  = nghost(w0mac(1,1))
    endif


    !=========================================================================
    ! initialize
    !=========================================================================
    Mach_max = ZERO


    !=========================================================================
    ! loop over the levels and compute the global quantities
    !=========================================================================
    do n = 1, nlevs

       ! initialize the local (processor's version) and level quantities to 0
       Mach_max_level = ZERO
       Mach_max_local = ZERO


       !----------------------------------------------------------------------
       ! loop over boxes in a given level
       !----------------------------------------------------------------------
       do i = 1, s(n)%nboxes
          if ( multifab_remote(s(n), i) ) cycle

          sp => dataptr(s(n) , i)
          rhnp => dataptr(rho_Hnuc(n), i)
          rhep => dataptr(rho_Hext(n), i)
          rwp => dataptr(rho_omegadot(n), i)
          up => dataptr(u(n) , i)

          lo =  lwb(get_box(s(n), i))
          hi =  upb(get_box(s(n), i))

          select case (dm)

          case (1)
             if (n .eq. nlevs) then
                call diag_1d(n,time,dt,dx(n,:), &
                             sp(:,1,1,:),ng_s, &
                             rhnp(:,1,1,1),ng_rhn, &
                             rhep(:,1,1,1),ng_rhe, &
                             rwp(:,1,1,:),ng_rw, &
                             rho0(n,:),rhoh0(n,:), &
                             p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                             up(:,1,1,:),ng_u, &
                             w0(n,:), &
                             lo,hi, &
                             Mach_max_local)
             else
                mp => dataptr(mla%mask(n), i)
                call diag_1d(n,time,dt,dx(n,:), &
                             sp(:,1,1,:),ng_s, &
                             rhnp(:,1,1,1),ng_rhn, &
                             rhep(:,1,1,1),ng_rhe, &
                             rwp(:,1,1,:),ng_rw, &
                             rho0(n,:),rhoh0(n,:), &
                             p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                             up(:,1,1,:),ng_u, &
                             w0(n,:), &
                             lo,hi, &
                             Mach_max_local, &
                             mp(:,1,1,1))
             endif

          case (2)
             if (n .eq. nlevs) then
                call diag_2d(n,time,dt,dx(n,:), &
                             sp(:,:,1,:),ng_s, &
                             rhnp(:,:,1,1),ng_rhn, &
                             rhep(:,:,1,1),ng_rhe, &
                             rwp(:,:,1,:),ng_rw, &
                             rho0(n,:),rhoh0(n,:), &
                             p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                             up(:,:,1,:),ng_u, &
                             w0(n,:), &
                             lo,hi, &
                             Mach_max_local)
             else
                mp => dataptr(mla%mask(n), i)
                call diag_2d(n,time,dt,dx(n,:), &
                             sp(:,:,1,:),ng_s, &
                             rhnp(:,:,1,1),ng_rhn, &
                             rhep(:,:,1,1),ng_rhe, &
                             rwp(:,:,1,:),ng_rw, &
                             rho0(n,:),rhoh0(n,:), &
                             p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                             up(:,:,1,:),ng_u, &
                             w0(n,:), &
                             lo,hi, &
                             Mach_max_local, &
                             mp(:,:,1,1))
             endif

          case (3)
             if (spherical == 1) then

                np => dataptr(normal(n) , i)
                w0rp => dataptr(w0r_cart(n), i)
                w0xp => dataptr(w0mac(n,1), i)
                w0yp => dataptr(w0mac(n,2), i)
                w0zp => dataptr(w0mac(n,3), i)

                if (n .eq. nlevs) then
                   call diag_3d_sph(n,time,dt,dx(n,:), &
                                    sp(:,:,:,:),ng_s, &
                                    rhnp(:,:,:,1),ng_rhn, &
                                    rhep(:,:,:,1),ng_rhe, &
                                    rwp(:,:,:,:),ng_rw, &
                                    rho0(n,:),rhoh0(n,:), &
                                    p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                                    up(:,:,:,:),ng_u, &
                                    w0rp(:,:,:,1), ng_w, &
                                    w0xp(:,:,:,1),w0yp(:,:,:,1),w0zp(:,:,:,1),ng_wm, &
                                    np(:,:,:,:),ng_n, &
                                    lo,hi, &
                                    Mach_max_local)
                else
                   mp => dataptr(mla%mask(n), i)
                   call diag_3d_sph(n,time,dt,dx(n,:), &
                                    sp(:,:,:,:),ng_s, &
                                    rhnp(:,:,:,1),ng_rhn, &
                                    rhep(:,:,:,1),ng_rhe, &
                                    rwp(:,:,:,:),ng_rw, &
                                    rho0(n,:),rhoh0(n,:), &
                                    p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                                    up(:,:,:,:),ng_u, &
                                    w0rp(:,:,:,1), ng_w, &
                                    w0xp(:,:,:,1),w0yp(:,:,:,1),w0zp(:,:,:,1),ng_wm, &
                                    np(:,:,:,:),ng_n, &
                                    lo,hi, &
                                    Mach_max_local, &
                                    mp(:,:,:,1))
                endif

             else
                if (n .eq. nlevs) then
                   call diag_3d(n,time,dt,dx(n,:), &
                                sp(:,:,:,:),ng_s, &
                                rhnp(:,:,:,1),ng_rhn, &
                                rhep(:,:,:,1),ng_rhe, &
                                rwp(:,:,:,:),ng_rw, &
                                rho0(n,:),rhoh0(n,:), &
                                p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                                up(:,:,:,:),ng_u, &
                                w0(n,:), &
                                lo,hi, &
                                Mach_max_local)
                else
                   mp => dataptr(mla%mask(n), i)
                   call diag_3d(n,time,dt,dx(n,:), &
                                sp(:,:,:,:),ng_s, &
                                rhnp(:,:,:,1),ng_rhn, &
                                rhep(:,:,:,1),ng_rhe, &
                                rwp(:,:,:,:),ng_rw, &
                                rho0(n,:),rhoh0(n,:), &
                                p0(n,:),tempbar(n,:),gamma1bar(n,:), &
                                up(:,:,:,:),ng_u, &
                                w0(n,:), &
                                lo,hi, &
                                Mach_max_local, &
                                mp(:,:,:,1))
                endif

             endif
          end select
       end do

       !----------------------------------------------------------------------
       ! do the appropriate parallel reduction for the current level
       !----------------------------------------------------------------------

       ! NOTE: only the I/O Processor will have the correct reduced value
       call parallel_reduce(Mach_max_level, Mach_max_local, MPI_MAX, &
                            proc = parallel_IOProcessorNode())


       !----------------------------------------------------------------------
       ! reduce the current level's data with the global data
       !----------------------------------------------------------------------
       if (parallel_IOProcessor()) then
          Mach_max = max(Mach_max, Mach_max_level)
       endif

    end do


    !=========================================================================
    ! normalize 
    !=========================================================================

    ! normalize any integral quantities here


    !=========================================================================
    ! output
    !=========================================================================
 999 format("# job name: ",a)
1000 format(1x,10(g24.10,1x))
1001 format("#",10(a24,1x))

    if (parallel_IOProcessor()) then

       ! open the diagnostic files for output, taking care not to overwrite
       ! an existing file
       un = unit_new()
       inquire(file="maestro_diag.out", exist=lexist)
       if (lexist) then
          open(unit=un, file="maestro_diag.out", &
               status="old", position="append")
       else
          open(unit=un, file="maestro_diag.out", status="new")
       endif


       ! write out the headers
       if (firstCall_io) then

          ! radvel
          write (un, *) " "
          write (un, 999) trim(job_name)
          write (un, 1001) "time", "max Mach #"

          firstCall_io = .false.
       endif

       ! write out the data
       write (un,1000) time, Mach_max

       close(un)

    endif

    call destroy(bpt)

  end subroutine diag


  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine flush_diag()
    ! flush_diag is called immediately before checkpointing.  If an
    ! implementation of these diagnostic routines wants to buffer the
    ! data a write out a lot of timestep's worth of information all 
    ! at once, flush_diag() is the routine that should do the writing.

  end subroutine flush_diag


  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine diag_1d(n,time,dt,dx, &
                     s,ng_s, &
                     rho_Hnuc,ng_rhn, &
                     rho_Hext,ng_rhe, &
                     rho_omegadot,ng_rw, &
                     rho0,rhoh0,p0,tempbar,gamma1bar, &
                     u,ng_u, &
                     w0, &
                     lo,hi, &
                     Mach_max, &
                     mask)

    use variables, only: rho_comp, spec_comp, temp_comp
    use bl_constants_module
    use network, only: nspec
    use probin_module, only: prob_lo
    use eos_module

    integer, intent(in) :: n, lo(:), hi(:), ng_s, ng_u, ng_rhn, ng_rhe, ng_rw
    real (kind=dp_t), intent(in   ) ::         s(lo(1)-ng_s:,:)
    real (kind=dp_t), intent(in   ) ::  rho_Hnuc(lo(1)-ng_rhn:)
    real (kind=dp_t), intent(in   ) ::  rho_Hext(lo(1)-ng_rhe:)
    real (kind=dp_t), intent(in   ) :: rho_omegadot(lo(1)-ng_rw:,:)
    real (kind=dp_t), intent(in   ) :: rho0(0:), rhoh0(0:), &
                                         p0(0:),tempbar(0:),gamma1bar(0:)
    real (kind=dp_t), intent(in   ) ::      u(lo(1)-ng_u:,:)
    real (kind=dp_t), intent(in   ) :: w0(0:)
    real (kind=dp_t), intent(in   ) :: time, dt, dx(:)
    real (kind=dp_t), intent(inout) :: Mach_max
    logical,          intent(in   ), optional :: mask(lo(1):)

    !     Local variables
    integer            :: i
    real (kind=dp_t)   :: weight
    logical            :: cell_valid
    real (kind=dp_t)   :: x
    real (kind=dp_t)   :: vel


    ! weight is the factor by which the volume of a cell at the current level
    ! relates to the volume of a cell at the coarsest level of refinement.
    weight = 1.d0 / 2.d0**(n-1)

    do i = lo(1), hi(1)
       x = prob_lo(1) + (dble(i) + HALF) * dx(1)

       cell_valid = .true.
       if (present(mask)) then
          if ( (.not. mask(i)) ) cell_valid = .false.
       endif
       
       if (cell_valid) then

          ! vel is the magnitude of the velocity, including w0
          vel = sqrt( (u(i,1) + HALF*(w0(i) + w0(i+1)) )**2 )

             
          ! call the EOS to get the sound speed and internal energy       
          temp_eos(1) = s(i,temp_comp)
          den_eos(1)  = s(i,rho_comp)
          xn_eos(1,:) = s(i,spec_comp:spec_comp+nspec-1)/den_eos(1)

          call eos(eos_input_rt, den_eos, temp_eos, &
                   npts, &
                   xn_eos, &
                   p_eos, h_eos, e_eos, &
                   cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                   dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                   dpdX_eos, dhdX_eos, &
                   gam1_eos, cs_eos, s_eos, &
                   dsdt_eos, dsdr_eos, &
                   .false.)


          ! max Mach number                                       
          Mach_max = max(Mach_max,vel/cs_eos(1))

       endif  ! cell valid

    enddo

  end subroutine diag_1d


  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine diag_2d(n,time,dt,dx, &
                     s,ng_s, &
                     rho_Hnuc,ng_rhn, &
                     rho_Hext,ng_rhe, &
                     rho_omegadot,ng_rw, &
                     rho0,rhoh0,p0,tempbar,gamma1bar, &
                     u,ng_u, &
                     w0, &
                     lo,hi, &
                     Mach_max, &
                     mask)

    use variables, only: rho_comp, spec_comp, temp_comp
    use bl_constants_module
    use network, only: nspec
    use probin_module, only: prob_lo
    use eos_module

    integer, intent(in) :: n, lo(:), hi(:), ng_s, ng_u, ng_rhn, ng_rhe, ng_rw
    real (kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s:,lo(2)-ng_s:,:)
    real (kind=dp_t), intent(in   ) :: rho_Hnuc(lo(1)-ng_rhn:,lo(2)-ng_rhn:)
    real (kind=dp_t), intent(in   ) :: rho_Hext(lo(1)-ng_rhe:,lo(2)-ng_rhe:)
    real (kind=dp_t), intent(in   ) :: rho_omegadot(lo(1)-ng_rw:,lo(2)-ng_rw:,:)
    real (kind=dp_t), intent(in   ) :: rho0(0:), rhoh0(0:), &
                                         p0(0:),tempbar(0:),gamma1bar(0:)
    real (kind=dp_t), intent(in   ) ::      u(lo(1)-ng_u:,lo(2)-ng_u:,:)
    real (kind=dp_t), intent(in   ) :: w0(0:)
    real (kind=dp_t), intent(in   ) :: time, dt, dx(:)
    real (kind=dp_t), intent(inout) :: Mach_max
    logical,          intent(in   ), optional :: mask(lo(1):,lo(2):)

    !     Local variables
    integer            :: i, j
    real (kind=dp_t)   :: weight
    logical            :: cell_valid
    real (kind=dp_t)   :: x, y
    real (kind=dp_t)   :: vel


    ! weight is the factor by which the volume of a cell at the current level
    ! relates to the volume of a cell at the coarsest level of refinement.
    weight = 1.d0 / 4.d0**(n-1)

    do j = lo(2), hi(2)
       y = prob_lo(2) + (dble(j) + HALF) * dx(2)
       
       do i = lo(1), hi(1)
          x = prob_lo(1) + (dble(i) + HALF) * dx(1)

          cell_valid = .true.
          if (present(mask)) then
             if ( (.not. mask(i,j)) ) cell_valid = .false.
          endif

          if (cell_valid) then

             ! vel is the magnitude of the velocity, including w0
             vel = sqrt(  u(i,j,1)**2 + &
                        ( u(i,j,2) + HALF*(w0(j) + w0(j+1)) )**2 )

             
             ! call the EOS to get the sound speed and internal energy       
             temp_eos(1) = s(i,j,temp_comp)
             den_eos(1)  = s(i,j,rho_comp)
             xn_eos(1,:) = s(i,j,spec_comp:spec_comp+nspec-1)/den_eos(1)

             call eos(eos_input_rt, den_eos, temp_eos, &
                      npts, &
                      xn_eos, &
                      p_eos, h_eos, e_eos, &
                      cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                      dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                      dpdX_eos, dhdX_eos, &
                      gam1_eos, cs_eos, s_eos, &
                      dsdt_eos, dsdr_eos, &
                      .false.)


             ! max Mach number                                       
             Mach_max = max(Mach_max,vel/cs_eos(1))

          endif  ! cell valid

       enddo
    enddo

  end subroutine diag_2d


  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine diag_3d(n,time,dt,dx, &
                     s,ng_s, &
                     rho_Hnuc,ng_rhn, &
                     rho_Hext,ng_rhe, &
                     rho_omegadot,ng_rw, &
                     rho0,rhoh0,p0,tempbar,gamma1bar, &
                     u,ng_u, &
                     w0, &
                     lo,hi, &
                     Mach_max, &
                     mask)

    use variables, only: rho_comp, spec_comp, temp_comp
    use bl_constants_module
    use network, only: nspec
    use probin_module, only: prob_lo
    use eos_module

    integer, intent(in) :: n, lo(:), hi(:), ng_s, ng_u, ng_rhn, ng_rhe, ng_rw
    real (kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s:,lo(2)-ng_s:,lo(3)-ng_s:,:)
    real (kind=dp_t), intent(in   ) :: rho_Hnuc(lo(1)-ng_rhn:,lo(2)-ng_rhn:,lo(3)-ng_rhn:)
    real (kind=dp_t), intent(in   ) :: rho_Hext(lo(1)-ng_rhe:,lo(2)-ng_rhe:,lo(3)-ng_rhe:)
    real (kind=dp_t), intent(in   ) :: rho_omegadot(lo(1)-ng_rw:,lo(2)-ng_rw:,lo(3)-ng_rw:,:)
    real (kind=dp_t), intent(in   ) :: rho0(0:), rhoh0(0:), &
                                         p0(0:),tempbar(0:),gamma1bar(0:)
    real (kind=dp_t), intent(in   ) ::      u(lo(1)-ng_u:,lo(2)-ng_u:,lo(3)-ng_u:,:)
    real (kind=dp_t), intent(in   ) :: w0(0:)
    real (kind=dp_t), intent(in   ) :: time, dt, dx(:)
    real (kind=dp_t), intent(inout) :: Mach_max
    logical,          intent(in   ), optional :: mask(lo(1):,lo(2):,lo(3):)

    !     Local variables
    integer            :: i, j, k
    real (kind=dp_t)   :: weight
    logical            :: cell_valid
    real (kind=dp_t)   :: x, y, z
    real (kind=dp_t)   :: vel


    ! weight is the factor by which the volume of a cell at the current level
    ! relates to the volume of a cell at the coarsest level of refinement.
    weight = 1.d0 / 8.d0**(n-1)

    do k = lo(3), hi(3)
       z = prob_lo(3) + (dble(k) + HALF) * dx(3)

       do j = lo(2), hi(2)
          y = prob_lo(2) + (dble(j) + HALF) * dx(2)
       
          do i = lo(1), hi(1)
             x = prob_lo(1) + (dble(i) + HALF) * dx(1)

             cell_valid = .true.
             if (present(mask)) then
                if ( (.not. mask(i,j,k)) ) cell_valid = .false.
             endif

             if (cell_valid) then

                ! vel is the magnitude of the velocity, including w0
                vel = sqrt(  u(i,j,k,1)**2 + &
                             u(i,j,k,2)**2 + &
                           ( u(i,j,k,3) + HALF*(w0(k) + w0(k+1)) )**2 )

             
                ! call the EOS to get the sound speed and internal energy       
                temp_eos(1) = s(i,j,k,temp_comp)
                den_eos(1)  = s(i,j,k,rho_comp)
                xn_eos(1,:) = s(i,j,k,spec_comp:spec_comp+nspec-1)/den_eos(1)

                call eos(eos_input_rt, den_eos, temp_eos, &
                         npts, &
                         xn_eos, &
                         p_eos, h_eos, e_eos, &
                         cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                         dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                         dpdX_eos, dhdX_eos, &
                         gam1_eos, cs_eos, s_eos, &
                         dsdt_eos, dsdr_eos, &
                         .false.)


                ! max Mach number                                       
                Mach_max = max(Mach_max,vel/cs_eos(1))

             endif  ! cell valid

          enddo
       enddo
    enddo

  end subroutine diag_3d


  !xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  subroutine diag_3d_sph(n,time,dt,dx, &
                         s,ng_s, &
                         rho_Hnuc,ng_rhn, &
                         rho_Hext,ng_rhe, &
                         rho_omegadot,ng_rw, &
                         rho0,rhoh0,p0,tempbar,gamma1bar, &
                         u,ng_u, &
                         w0r,ng_w, &
                         w0macx,w0macy,w0macz,ng_wm, &
                         normal,ng_n, &
                         lo,hi, &                         
                         Mach_max, &
                         mask)

    use variables, only: rho_comp, spec_comp, temp_comp
    use bl_constants_module
    use network, only: nspec
    use probin_module, only: prob_lo
    use eos_module

    integer, intent(in) :: n, lo(:), hi(:), ng_s, ng_u, ng_rhn, ng_rhe, ng_rw, ng_w, ng_wm, ng_n
    real (kind=dp_t), intent(in   ) ::      s(lo(1)-ng_s:,lo(2)-ng_s:,lo(3)-ng_s:,:)
    real (kind=dp_t), intent(in   ) :: rho_Hnuc(lo(1)-ng_rhn:,lo(2)-ng_rhn:,lo(3)-ng_rhn:)
    real (kind=dp_t), intent(in   ) :: rho_Hext(lo(1)-ng_rhe:,lo(2)-ng_rhe:,lo(3)-ng_rhe:)
    real (kind=dp_t), intent(in   ) :: rho_omegadot(lo(1)-ng_rw:,lo(2)-ng_rw:,lo(3)-ng_rw:,:)
    real (kind=dp_t), intent(in   ) :: rho0(0:), rhoh0(0:), &
                                         p0(0:),tempbar(0:),gamma1bar(0:)
    real (kind=dp_t), intent(in   ) ::      u(lo(1)-ng_u:,lo(2)-ng_u:,lo(3)-ng_u:,:)
    real (kind=dp_t), intent(in   ) ::      w0r(lo(1)-ng_w:  ,lo(2)-ng_w:  ,lo(3)-ng_w:)
    real (kind=dp_t), intent(in   ) ::   w0macx(lo(1)-ng_wm: ,lo(2)-ng_wm: ,lo(3)-ng_wm:)
    real (kind=dp_t), intent(in   ) ::   w0macy(lo(1)-ng_wm: ,lo(2)-ng_wm: ,lo(3)-ng_wm:)
    real (kind=dp_t), intent(in   ) ::   w0macz(lo(1)-ng_wm: ,lo(2)-ng_wm: ,lo(3)-ng_wm:)
    real (kind=dp_t), intent(in   ) ::   normal(lo(1)-ng_n:  ,lo(2)-ng_n:  ,lo(3)-ng_n:,:)
    real (kind=dp_t), intent(in   ) :: time, dt, dx(:)
    real (kind=dp_t), intent(inout) :: Mach_max
    logical,          intent(in   ), optional :: mask(lo(1):,lo(2):,lo(3):)

    !     Local variables
    integer            :: i, j, k
    real (kind=dp_t)   :: weight
    logical            :: cell_valid
    real (kind=dp_t)   :: x, y, z
    real (kind=dp_t)   :: vel


    ! weight is the factor by which the volume of a cell at the current level
    ! relates to the volume of a cell at the coarsest level of refinement.
    weight = 1.d0 / 8.d0**(n-1)

    do k = lo(3), hi(3)
       z = prob_lo(3) + (dble(k) + HALF) * dx(3)

       do j = lo(2), hi(2)
          y = prob_lo(2) + (dble(j) + HALF) * dx(2)
       
          do i = lo(1), hi(1)
             x = prob_lo(1) + (dble(i) + HALF) * dx(1)

             cell_valid = .true.
             if (present(mask)) then
                if ( (.not. mask(i,j,k)) ) cell_valid = .false.
             endif

             if (cell_valid) then

                ! vel is the magnitude of the velocity, including w0
                vel = sqrt( (u(i,j,k,1)+HALF*(w0macx(i,j,k)+w0macx(i+1,j,k)))**2 + &
                            (u(i,j,k,2)+HALF*(w0macy(i,j,k)+w0macy(i,j+1,k)))**2 + &
                            (u(i,j,k,3)+HALF*(w0macz(i,j,k)+w0macz(i,j,k+1)))**2)

             
                ! call the EOS to get the sound speed and internal energy       
                temp_eos(1) = s(i,j,k,temp_comp)
                den_eos(1)  = s(i,j,k,rho_comp)
                xn_eos(1,:) = s(i,j,k,spec_comp:spec_comp+nspec-1)/den_eos(1)

                call eos(eos_input_rt, den_eos, temp_eos, &
                         npts, &
                         xn_eos, &
                         p_eos, h_eos, e_eos, &
                         cv_eos, cp_eos, xne_eos, eta_eos, pele_eos, &
                         dpdt_eos, dpdr_eos, dedt_eos, dedr_eos, &
                         dpdX_eos, dhdX_eos, &
                         gam1_eos, cs_eos, s_eos, &
                         dsdt_eos, dsdr_eos, &
                         .false.)


                ! max Mach number                                       
                Mach_max = max(Mach_max,vel/cs_eos(1))

             endif  ! cell valid

          enddo
       enddo
    enddo

  end subroutine diag_3d_sph

end module diag_module
