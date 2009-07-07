! make_edge_state constructs the edge state of a variable, using a 
! second-order Taylor expansion in space (through dx/2) and time 
! (though dt/2). 
!
! If is_vel = .true., then we are computing the edge states for the
! velocity.
!
! If velpred = 1 (then is_vel should also be 1), and we are computing 
! the edge states for the MAC.  In this case, we only need the normal 
! edge states (i.e. the x-edge state for u, the y-edge state for v, ...)
!
! If velpred = 0, then we are computing all edge states for each 
! variable.  This is what is done for the final updates of the state 
! variables and velocity.

module make_edge_state_module

  use bl_types
  use bl_error_module

  implicit none

  private

  public :: make_edge_state_1d
  
contains

   subroutine make_edge_state_1d(s,sedge,w0,force,dt)

     use geometry, only: r_start_coord, r_end_coord, nr_fine, nr, numdisjointchunks, &
          nlevs_radial, dr
     use probin_module, only: slope_order, ppm_type
     use bl_constants_module
     use variables, only: rel_eps
     
     real(kind=dp_t), intent(in   ) ::     s(:,0:)
     real(kind=dp_t), intent(inout) :: sedge(:,0:)
     real(kind=dp_t), intent(in   ) ::    w0(:,0:)
     real(kind=dp_t), intent(in   ) :: force(:,0:)
     real(kind=dp_t), intent(in   ) :: dt
     
     real(kind=dp_t) :: dmin,dpls,ds,del,slim,sflag,ubardth,dth,dtdr,savg,u
     real(kind=dp_t) :: sigmap,sigmam,s6,D2,D2L,D2R,D2C,D2LIM,C,alphap,alpham,dI,sgn
     real(kind=dp_t) :: diff1,diff2,diff3,diff4
     
     integer :: r,lo,hi,n,i

     integer        , parameter :: cen=1, lim=2, flag=3, fromm=4
     real(kind=dp_t), parameter :: FOURTHIRDS = FOUR/THREE
        
     ! cell based indexing
     real(kind=dp_t) :: slope(nlevs_radial,0:nr_fine-1)
     real(kind=dp_t) :: dxscr(nlevs_radial,0:nr_fine-1,4)
     real(kind=dp_t) ::  dxvl(nlevs_radial,-1:nr_fine)
     real(kind=dp_t) ::    sp(nlevs_radial,0:nr_fine-1)
     real(kind=dp_t) ::    sm(nlevs_radial,0:nr_fine-1)
     real(kind=dp_t) ::    Ip(nlevs_radial,0:nr_fine-1)
     real(kind=dp_t) ::    Im(nlevs_radial,0:nr_fine-1)
     
     ! edge based indexing
     real(kind=dp_t) :: sedgel(nlevs_radial,0:nr_fine)
     real(kind=dp_t) :: sedger(nlevs_radial,0:nr_fine)
     
     dth = HALF*dt
     dtdr = dt/dr(1)

     dxvl = ZERO

     ! constant used in Colella 2008
     C = 1.25d0

     if (ppm_type .eq. 0) then
        
        ! compute slopes
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              if (slope_order .eq. 0) then

                 slope(n,:) = ZERO

              else if (slope_order .eq. 2) then

                 do r=lo,hi
                    if (r .eq. 0 .or. r .eq. nr(n)-1) then
                       ! set slopes next to domain boundaries to zero
                       slope(n,r) = ZERO
                    else
                       ! do standard limiting on interior cells
                       del = half*(s(n,r+1) - s(n,r-1))
                       dpls = two*(s(n,r+1) - s(n,r  ))
                       dmin = two*(s(n,r  ) - s(n,r-1))
                       slim = min(abs(dpls), abs(dmin))
                       slim = merge(slim, ZERO, dpls*dmin.gt.ZERO)
                       sflag = sign(ONE,del)
                       slope(n,r)= sflag*min(slim,abs(del))
                    end if
                 end do

              else if (slope_order .eq. 4) then

                 do r=lo,hi
                    if (r .eq. 0 .or. r .eq. nr(n)-1) then
                       ! set fromm slopes next to domain boundaries to zero
                       dxscr(n,r,fromm) = ZERO
                    else
                       ! do standard limiting on interior cells to compute temporary slopes
                       dxscr(n,r,cen) = half*(s(n,r+1)-s(n,r-1))
                       dpls = two*(s(n,r+1)-s(n,r  ))
                       dmin = two*(s(n,r  )-s(n,r-1))
                       dxscr(n,r,lim)= min(abs(dmin),abs(dpls))
                       dxscr(n,r,lim) = merge(dxscr(n,r,lim),ZERO,dpls*dmin.gt.ZERO)
                       dxscr(n,r,flag) = sign(ONE,dxscr(n,r,cen))
                       dxscr(n,r,fromm)= dxscr(n,r,flag) &
                            *min(dxscr(n,r,lim),abs(dxscr(n,r,cen)))
                    end if
                 end do

                 do r=lo,hi
                    if (r .eq. 0 .or. r .eq. nr(n)-1) then
                       ! set slopes adjacent to domain boundaries to zero
                       slope(n,r) = ZERO
                    else if (r .eq. r_start_coord(n,i) .or. r .eq. r_end_coord(n,i)) then
                       ! drop order to second-order limited differences at C-F interface
                       del = half*(s(n,r+1) - s(n,r-1))
                       dpls = two*(s(n,r+1) - s(n,r  ))
                       dmin = two*(s(n,r  ) - s(n,r-1))
                       slim = min(abs(dpls), abs(dmin))
                       slim = merge(slim, ZERO, dpls*dmin.gt.ZERO)
                       sflag = sign(ONE,del)
                       slope(n,r)= sflag*min(slim,abs(del))
                    else
                       ! fourth-order limited slopes on interior
                       ds = FOURTHIRDS*dxscr(n,r,cen) - SIXTH*(dxscr(n,r+1,fromm) &
                            + dxscr(n,r-1,fromm))
                       slope(n,r) = dxscr(n,r,flag)*min(abs(ds),dxscr(n,r,lim))
                    end if
                 end do

              end if ! which slope order

           end do ! loop over disjointchunks
        end do ! loop over levels

     else if (ppm_type .eq. 1) then

        ! interpolate s to radial edges, store these temporary values into sedgel
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)
        
              ! compute van Leer slopes away from domain boundaries
              ! leave van Leer slopes at domain boundaries set to zero
              do r=lo-1,hi+1
                 if (r .gt. 0 .and. r .lt. nr(n)-1) then
                    del  = HALF * (s(n,r+1) - s(n,r-1))
                    dmin = TWO  * (s(n,r  ) - s(n,r-1))
                    dpls = TWO  * (s(n,r+1) - s(n,r  ))
                    dxvl(n,r) = sign(ONE,del)*min(abs(del),abs(dmin),abs(dpls))
                 end if
              end do

              ! 4th order interpolation of s to radial faces
              do r=lo,hi+1
                 if (r .eq. 0) then
                    sedgel(n,r) = s(n,r)
                 else if (r .eq. nr(n)) then
                    sedgel(n,r) = s(n,r-1)
                 else
                    sedgel(n,r) = HALF*(s(n,r)+s(n,r-1)) - SIXTH*(dxvl(n,r)-dxvl(n,r-1))
                    ! make sure sedgel lies in between adjacent cell-centered values
                    sedgel(n,r) = max(sedgel(n,r),min(s(n,r),s(n,r-1)))
                    sedgel(n,r) = min(sedgel(n,r),max(s(n,r),s(n,r-1)))
                 end if
              end do

           end do ! loop over disjointchunks
        end do ! loop over levels
        
     else if (ppm_type .eq. 2) then

        ! interpolate s to radial edges, store these temporary values into sedgel

        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              ! store centered differences in dxvl
              ! leave slopes at domain boundaries set to zero
              do r=lo-1,hi+1
                 if (r .gt. 0 .and. r .lt. nr(n)-1) then
                    dxvl(n,r) = HALF * (s(n,r+1) - s(n,r-1))
                 end if
              end do

              ! 4th order interpolation of s to radial faces
              do r=lo,hi+1
                 if (r .eq. 0) then
                    sedgel(n,r) = s(n,r)
                 else if (r .eq. nr(n)) then
                    sedgel(n,r) = s(n,r-1)
                 else
                    sedgel(n,r) = HALF*(s(n,r)+s(n,r-1)) - SIXTH*(dxvl(n,r)-dxvl(n,r-1))
                    if (r .ge. 2 .and. r .le. nr(n)-2) then
                       ! if sedge is not in between the neighboring s values, we limit
                       if (sedgel(n,r) .lt. min(s(n,r),s(n,r-1)) .or. &
                            sedgel(n,r) .gt. max(s(n,r),s(n,r-1))) then
                          D2  = (THREE/dr(1)**2)*(s(n,r-1)-TWO*sedgel(n,r)+s(n,r))
                          D2L = (ONE/dr(1)**2)*(s(n,r-2)-TWO*s(n,r-1)+s(n,r))
                          D2R = (ONE/dr(1)**2)*(s(n,r-1)-TWO*s(n,r)+s(n,r+1))
                          if (sign(ONE,D2) .eq. sign(ONE,D2L) .and. &
                               sign(ONE,D2) .eq. sign(ONE,D2R)) then
                             sedgel(n,r) = HALF*(s(n,r-1)+s(n,r)) - (dr(1)**2/THREE) &
                                  *sign(ONE,D2)*min(C*abs(D2L),C*abs(D2R),abs(D2))
                          else
                             sedgel(n,r) = HALF*(s(n,r-1)+s(n,r))
                          end if
                       end if
                    end if
                 end if
              end do

           end do
        end do 

     else
        call bl_error("make_edge_state_1d: unknown ppm_type")
     end if

     if (ppm_type .ge. 1) then

        ! fill copy sedgel into sp and sm
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)
              
              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)
              
              do r=lo,hi
                 sp(n,r) = sedgel(n,r+1)
                 sm(n,r) = sedgel(n,r  )
              end do
              
           end do ! loop over disjointchunks
        end do ! loop over levels

     end if

     ! limit sp and sm
     if (ppm_type .eq. 1) then

        ! modify using quadratic limiters
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              do r=lo,hi
                 if ((sp(n,r)-s(n,r))*(s(n,r)-sm(n,r)) .le. ZERO) then
                    sp(n,r) = s(n,r)
                    sm(n,r) = s(n,r)
                 else if (abs(sp(n,r)-s(n,r)) .ge. TWO*abs(sm(n,r)-s(n,r))) then
                    sp(n,r) = THREE*s(n,r) - TWO*sm(n,r)
                 else if (abs(sm(n,r)-s(n,r)) .ge. TWO*abs(sp(n,r)-s(n,r))) then
                    sm(n,r) = THREE*s(n,r) - TWO*sp(n,r)
                 end if
              end do

           end do ! loop over disjointchunks
        end do ! loop over levels

     else if (ppm_type .eq. 2) then

        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              ! modify using Colella 2008 limiters
              if (r .ge. 2 .and. r .le. nr(n)-3) then
                 
                 diff1 = sp(n,r)-s(n,r)
                 diff2 = s(n,r)-sm(n,r)
                 diff3 = s(n,r+1)-s(n,r)
                 diff4 = s(n,r)-s(n,r-1)

                 if (abs(diff1) .le. rel_eps) diff1 = ZERO
                 if (abs(diff2) .le. rel_eps) diff2 = ZERO
                 if (abs(diff3) .le. rel_eps) diff3 = ZERO
                 if (abs(diff4) .le. rel_eps) diff4 = ZERO

                 if (diff1*diff2 .le. ZERO .or. &
                     diff3*diff4 .le. ZERO ) then
                    s6 = SIX*s(n,r) - THREE*(sm(n,r)+sp(n,r))
                    D2  = -TWO*s6/dr(1)**2
                    D2C = (ONE/dr(1)**2)*(s(n,r-1)-TWO*s(n,r)+s(n,r+1))
                    D2L = (ONE/dr(1)**2)*(s(n,r-2)-TWO*s(n,r-1)+s(n,r))
                    D2R = (ONE/dr(1)**2)*(s(n,r)-TWO*s(n,r+1)+s(n,r+2))
                    if (sign(ONE,D2) .eq. sign(ONE,D2C) .and. &
                         sign(ONE,D2) .eq. sign(ONE,D2L) .and. &
                         sign(ONE,D2) .eq. sign(ONE,D2R) .and. &
                         D2 .ne. ZERO) then
                       D2LIM = sign(ONE,D2)*min(C*abs(D2C),C*abs(D2L),C*abs(D2R),abs(D2))
                       sp(n,r) = s(n,r) + (sp(n,r)-s(n,r))*(D2LIM/D2)
                       sm(n,r) = s(n,r) + (sm(n,r)-s(n,r))*(D2LIM/D2)
                    else
                       sp(n,r) = s(n,r)
                       sm(n,r) = s(n,r)
                    end if
                 else
                    alphap = sp(n,r)-s(n,r)
                    alpham = sm(n,r)-s(n,r)
                    if (abs(alphap) .ge. TWO*abs(alpham)) then
                       dI = -alphap**2 / (FOUR*(alphap+alpham))
                       ds = s(n,r+1)-s(n,r)
                       sgn = sign(ONE,s(n,r+1)-s(n,r-1))
                       if (sgn*dI .ge. sgn*ds) then
                          sp(n,r) = s(n,r) - (TWO*ds + TWO*sgn*sqrt(ds**2 - ds*alpham))
                       end if
                    else if (abs(alpham) .ge. TWO*abs(alphap)) then
                       dI = -alpham**2 / (FOUR*(alphap+alpham))
                       ds = s(n,r-1)-s(n,r)
                       sgn = sign(ONE,s(n,r+1)-s(n,r-1))
                       if (sgn*dI .ge. sgn*ds) then
                          sm(n,r) = s(n,r) - (TWO*ds + TWO*sgn*sqrt(ds**2 - ds*alphap))
                       end if
                    end if
                 end if
              end if

           end do
        end do

     end if

     ! compute Ip and Im
     if (ppm_type .ge. 1) then
        
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              do r=lo,hi
                 sigmap = abs(w0(n,r+1))*dtdr
                 sigmam = abs(w0(n,r  ))*dtdr
                 s6 = SIX*s(n,r) - THREE*(sm(n,r)+sp(n,r))
                 if (w0(n,r+1) .gt. rel_eps) then
                    Ip(n,r) = sp(n,r) - (sigmap/TWO)*(sp(n,r)-sm(n,r)-(ONE-TWO3RD*sigmap)*s6)
                 else
                    Ip(n,r) = s(n,r)
                 end if
                 if (w0(n,r) .lt. -rel_eps) then
                    Im(n,r) = sm(n,r) + (sigmam/TWO)*(sp(n,r)-sm(n,r)+(ONE-TWO3RD*sigmam)*s6)
                 else
                    Im(n,r) = s(n,r)
                 end if
              end do

           end do ! loop over disjointchunks
        end do ! loop over levels

     end if

     ! compute sedgel and sedger
     if (ppm_type .eq. 0) then
        
        ! use taylor series
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              do r = lo,hi
                 u = HALF*(w0(n,r)+w0(n,r+1))
                 ubardth = dth*u/dr(n)
                 sedgel(n,r+1)= s(n,r) + (HALF-ubardth)*slope(n,r) + dth * force(n,r)
                 sedger(n,r  )= s(n,r) - (HALF+ubardth)*slope(n,r) + dth * force(n,r)
              end do

           end do ! loop over disjointchunks
        end do ! loop over levels

     else

        ! now extrapolate to faces
        do n=1,nlevs_radial
           do i=1,numdisjointchunks(n)

              lo = r_start_coord(n,i)
              hi = r_end_coord(n,i)

              do r=lo,hi
                 sedgel(n,r+1) = Ip(n,r) + dth * force(n,r)
                 sedger(n,r  ) = Im(n,r) + dth * force(n,r)
              end do

           end do
        end do

     end if

     ! sync up edge states at coarse-fine interface
     do n=1,nlevs_radial
        do i=1,numdisjointchunks(n)

           lo = r_start_coord(n,i)
           hi = r_end_coord(n,i)

           ! if we are not at the finest level, copy in the sedger and sedgel states 
           ! from the next finer level at the c-f interface
           if (n .ne. nlevs_radial) then
              sedger(n,r_start_coord(n+1,i)/2) = sedger(n+1,r_start_coord(n+1,i))
              sedgel(n,(r_end_coord(n+1,i)+1)/2) = sedgel(n+1,r_end_coord(n+1,i)+1)
           end if

           ! if we are not at the coarsest level, copy in the sedgel and sedger states 
           ! from the next coarser level at the c-f interface
           if (n .ne. 1) then
              sedgel(n,lo) = sedgel(n-1,lo/2)
              sedger(n,hi+1) = sedger(n-1,(hi+1)/2)
           end if

        end do ! loop over disjointchunks
     end do ! loop over levels

     ! solve Riemann problem to get final edge state
     do n=1,nlevs_radial
        do i=1,numdisjointchunks(n)

           lo = r_start_coord(n,i)
           hi = r_end_coord(n,i)

           do r=lo,hi+1
              if (r .eq. 0) then
                 ! pick interior state at lo domain boundary
                 sedge(n,r) = sedger(n,r)
              else if (r .eq. nr(n)) then
                 ! pick interior state at hi domain boundary
                 sedge(n,r) = sedgel(n,r)
              else
                 ! upwind
                 sedge(n,r)=merge(sedgel(n,r),sedger(n,r),w0(n,r).gt.ZERO)
                 savg = HALF*(sedger(n,r) + sedgel(n,r))
                 sedge(n,r)=merge(savg,sedge(n,r),abs(w0(n,r)) .lt. rel_eps)
              end if
           end do

        end do  ! loop over disjointchunks
     end do ! loop over levels

   end subroutine make_edge_state_1d
   
 end module make_edge_state_module
