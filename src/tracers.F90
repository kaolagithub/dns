#include "macros.h"
module tracers
use params
implicit none
!
!  Tracers module
!
!  all cpus have a copy of all tracers.  But each tracer "belongs"
!  to one pe, and the value on all other pe's will be 0.  
!
!  1. call init_tracers with the number of tracers desired
!  2. initialize tracers::xtracer, ytracer, ztracer 
!  3. call advance_tracers(rhs) to advance them one time step
!  
!
!  tracer(:,1)  = xcord
!  tracer(:,2)  = ycord
!  tracer(:,3)  = zcord   (if ndim==3)
!  tracer(:,ndim+1) = 'alf', a particle marker used for insertion
!
!  tracer_old(:,1:ndim)   used for rk4 time stepping
!  tracer_tmp(:,1:ndim)   used for rk4 time stepping
!
!  tracer_work(:,1:ndim+1)  used for MPI buffer, other copy operations
!
integer :: numt=0
integer :: numt_max=0
real*8,allocatable :: tracer(:,:)
real*8,private,allocatable :: tracer_old(:,:)
real*8,private,allocatable :: tracer_tmp(:,:)
real*8,private,allocatable :: tracer_work(:,:)

character(len=80),private :: message


contains

subroutine allocate_tracers(in_numt)
implicit none
integer :: in_numt

numt=in_numt
numt_max=2*in_numt

if (allocated(tracer)) then
   call abort("allocate_tracers(): error: tracers allready allocated")
endif

allocate(tracer(numt_max,ndim+1))  
allocate(tracer_work(numt_max,ndim+1))  
allocate(tracer_old(numt_max,ndim))  
allocate(tracer_tmp(numt_max,ndim))  

tracer=-1d100

end subroutine




subroutine enlarge_tracers()
!
! double the size of all tracer_* arrays.
! preserve data in tracer() array ONLY
!
implicit none
integer :: in_numt


numt_max=2*numt_max
call print_message("Increasig size of tracer array")
write(message,'(a,i5)') "new size=",numt_max
call print_message(message)


tracer_work=tracer
deallocate(tracer)
allocate(tracer(numt_max,ndim+1))  
tracer=-1d100
tracer(1:numt,:)=tracer_work(1:numt,:)

deallocate(tracer_work)
allocate(tracer_work(numt_max,ndim+1))  
deallocate(tracer_old)
allocate(tracer_old(numt_max,ndim))  
deallocate(tracer_tmp)
allocate(tracer_tmp(numt_max,ndim))  

end subroutine


subroutine tracers_restart(fpe)
!
!  read==1   read tracers from restart file
!  read==0   write tracers to restart file
!
implicit none
integer :: fpe
real*8 :: time=0

call print_message("Restart tracer data from file restart.tracer")
call tracers_io(1,fpe,'restart.tracer')
end subroutine


subroutine tracers_save(fpe,time)
!
!  read==1   read tracers from restart file
!  read==0   write tracers to restart file
!
use params
implicit none
integer :: fpe
real*8 :: time
character(len=280) :: fname

if (numt==0) return

write(message,'(f10.4)') 10000.0000 + time
fname = rundir(1:len_trim(rundir)) // runname(1:len_trim(runname)) // &
     message(2:10) // ".tracer"

call tracers_io(0,fpe,fname)
end subroutine





subroutine tracers_io(read,fpe,fname)
!
!  read==1   read tracers from restart file
!  read==0   write tracers to restart file
!
use params
use mpi
implicit none

integer :: read,fpe
character(len=*) :: fname

! local
CPOINTER :: fid
integer :: ierr,j,numt_in
real*8 :: x

if (my_pe==fpe) then

   if (read==1) then
      call copen(fname,"r",fid,ierr)
      if (ierr/=0) then
         write(message,'(a,i5)') "tracer_io(): Error opening file. Error no=",ierr
         call print_message(message)
         call print_message(fname)
         call abort("")
      endif
      call cread8e(fid,x,1,ierr)
      if (ierr/=1) then
         write(message,'(a,i5)') "tracer_io(): Error reading file"
         call print_message(message)
         call print_message(fname)
         call abort("")
      endif
      numt_in=x
      
      call cread8(fid,x,1)
      if (ndim+1 /= nint(x)) then
         call abort("Error: ndim in code not the same as ndim in tracers restart file")
      endif
      call allocate_tracers(numt_in)
      do j=1,ndim+1
         call cread8(fid,tracer(1,j),numt)
      enddo
      call cclose(fid,ierr)


   else
      call copen(fname,"w",fid,ierr)
      if (ierr/=0) then
         write(message,'(a,i5)') "tracer_io(): Error opening file. Error no=",ierr
         call print_message(message)
         call print_message(fname)
         call abort("")
      endif
      x=numt
      call cwrite8(fid,x,1)
      x=ndim+1
      call cwrite8(fid,x,1)
      do j=1,ndim+1
         call cwrite8(fid,tracer(1,j),numt)
      enddo
      call cclose(fid,ierr)
   endif
endif

#ifdef USE_MPI
if (read==1) then
   call MPI_bcast(numt,1,MPI_INTEGER,fpe,comm_3d ,ierr)
   if (my_pe/=fpe) then
      numt_in=numt
      call allocate_tracers(numt_in)      
   endif
   call MPI_bcast(tracer,(ndim+1)*numt_max,MPI_REAL8,fpe,comm_3d ,ierr)
endif
#endif



end subroutine










subroutine tracer_advance(psi,ugrid,rk4stage)
!
!  input:  psi  stream function
!          rk4stage  = 1,2,3,4 to denote which rk4 stage
!
!  work array: ugrid 
!
! stage 1:
!    tracer_old=tracer
!    tracer_tmp=tracer
!    RHS = interpolate psi to position of tracer_tmp
!    tracer = tracer + delt*RHS/6
!    tracer_tmp = tracer_old + delt*RHS/2
!   
! stage 2:
!    RHS = interpolate pso to poisition of tracer_tmp
!    tracer = tracer + delt*RHS/3
!    tracer_tmp = tracer_old + delt*RHS/2
!
! stage 3:
!    RHS = interpolate psi to position of tracer_tmp
!    tracer = tracer + delt*RHS/3
!    tracer_tmp = tracer_old + delt*RHS
!    
! stage 4:
!    RHS = interpolate psi to position of tracer_tmp
!    tracer = tracer + delt*RHS/6
!    tracer_tmp = tracer_old + 0*RHS (doesn't matter)
!    
!
!
use params
use mpi
use ghost
implicit none
real*8 :: psi(nx,ny)
real*8 :: ugrid(nx,ny,2)
integer :: rk4stage

!local
integer :: i,j,ii,jj,igrid,jgrid
real*8 :: trhs(ndim),c1,c2
real*8 :: Qint(4,ndim)
real*8 :: xc,yc,tmx1,tmx2
integer :: jc
integer :: ierr

if (numt==0) return
call wallclock(tmx1)

if (rk4stage==1) then
   tracer_tmp(:,1:ndim)=tracer(:,1:ndim)
   tracer_old(:,1:ndim)=tracer(:,1:ndim)
   c1=delt/6
   c2=delt/2
else if (rk4stage==2) then
   c1=delt/3
   c2=delt/2
else if (rk4stage==3) then
   c1=delt/3
   c2=delt
else if (rk4stage==4) then
   c1=delt/6
   c2=0
endif


do j=inty1,inty2
do i=intx1,intx2
      
      ugrid(i,j,1)=( 2*(psi(i,j+1)-psi(i,j-1))/3 -  &
           (psi(i,j+2)-psi(i,j-2))/12          )/dely
      
      ugrid(i,j,2)=-( 2*(psi(i+1,j)-psi(i-1,j))/3 -  &
           (psi(i+2,j)-psi(i-2,j))/12          )/delx
      
enddo
enddo

call ghost_update_x(ugrid,2)
call ghost_update_y(ugrid,2)


! keep the last point, along y=0 boundary, from crossing over.
! (velocity = x direction only, so this only happens from roundoff
tracer_tmp(numt,2)=0


! interpolate psi to position in tracer_tmp
do i=1,numt
   ! find cpu which owns the grid point tracer(i,:)
   if (xcord(intx1)<=tracer_tmp(i,1) .and. tracer_tmp(i,1)<xcord(intx2)+delx .and. &
       ycord(inty1)<=tracer_tmp(i,2) .and. tracer_tmp(i,2)<ycord(inty2)+dely ) then

      ! find igrid,jgrid so that point is in box:
      ! igrid-1,igrid,igrid+1,igrid+2   and jgrid-1,jgrid,jgrid+1,jgrid+2
      igrid = intx1 + floor( (tracer_tmp(i,1)-xcord(intx1))/delx )
      jgrid = inty1 + floor( (tracer_tmp(i,2)-ycord(inty1))/dely )
      ASSERT("advance_tracers(): igrid interp error",igrid<=intx2)
      ASSERT("advance_tracers(): jgrid interp error",jgrid<=inty2)


      ! interpolate trhs
      do jj=1,4
         ! interpolate xcord(igrid-1:igrid+2) to xcord=tracer(i,1)
         ! data  ugrid(igrid-1:igrid+2, jgrid-2+jj,:) 
         xc = 1 + (tracer_tmp(i,1)-xcord(igrid))/delx
         jc = jgrid-2+jj
         do j=1,ndim
            call interp4(ugrid(igrid-1,jc,j),ugrid(igrid,jc,j),&
                ugrid(igrid+1,jc,j),ugrid(igrid+2,jc,j),&
                xc,Qint(jj,j))
         enddo
      enddo
      ! interpolate ycord(jgrid-1:jgrid+2) to ycord=tracer(i,2)
      ! data:  Qint(1:4,j)
      yc = 1 + (tracer_tmp(i,2)-ycord(jgrid))/dely
      do j=1,ndim
         call interp4(Qint(1,j),Qint(2,j),Qint(3,j),Qint(4,j),yc,trhs(j))
      enddo

      ! advance
      do j=1,ndim
         tracer(i,j)=tracer(i,j)+c1*trhs(j)
         tracer_tmp(i,j)=tracer_old(i,j)+c2*trhs(j)
      enddo
   else
      ! point does not belong to my_pe, set position to -inf
      do j=1,ndim
         tracer(i,j)=-1d100
         tracer_tmp(i,j)=-1d100
      enddo
   endif
enddo



#ifdef USE_MPI
   tracer_work=tracer
   call MPI_allreduce(tracer_work,tracer,(ndim+1)*numt_max,MPI_REAL8,MPI_MAX,comm_3d,ierr)
   if (rk4stage/=4) then
      ! not necessary on last stage - we no longer need tracer_tmp
      tracer_work(:,1:ndim)=tracer_tmp(:,1:ndim)
      call MPI_allreduce(tracer_work,tracer_tmp,ndim*numt_max,MPI_REAL8,MPI_MAX,comm_3d,ierr)
   endif
#endif




if (rk4stage==4) then
   ! xcord set to -1d100 to denote off processor.  
   ! if any tracer has left *all* processors, abort:
   if (minval(tracer(1:numt,1))<g_xcord(1)) then
      call abort("tracer_advance(): point has left domain") 
   endif

   ! insert points into tracer() if necessary:
   if (numt>(3*numt_max/4)) call enlarge_tracers()
   j=numt
   call insert(tracer(1,1),tracer(1,2),tracer(1,ndim+1))
   if (j/=numt) then
      write(message,'(a,i5)') "tracers(): inserted points. numt=",numt
      call print_message(message)
   endif
endif



call wallclock(tmx2)
tims(16)=tims(16)+(tmx2-tmx1)
end subroutine






      SUBROUTINE interp4(y0,y1,y2,y3,newx,ynew)
!cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
!c     Interpolates "y" to xloc position
!
!
!     y0,y1,y2,y3 is data specified at points 0,1,2,3
!     newx should be a point between 0 and 3
!cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      implicit none
      integer i,n,xbeg
      real*8 x0,x1,x2,x3,y0,y1,y2,y3,ynew
      real*8 denom0,denom1,denom2,denom3,fact0,fact1,fact2,fact3,newx

      x0 = 0
      x1 = 1
      x2 = 2
      x3 = 3

      denom0 = -6  !(x0-x1)*(x0-x2)*(x0-x3)   ! (-1)(-2)(-3)=-6
      denom1 =  2  !(x1-x0)*(x1-x2)*(x1-x3)   ! ( 1)(-1)(-2)= 2
      denom2 = -2  !(x2-x0)*(x2-x1)*(x2-x3)   ! ( 2)( 1)(-1)=-2
      denom3 =  6  !(x3-x0)*(x3-x1)*(x3-x2)   ! ( 3)( 2)( 1)= 6

      fact0 = (newx-x1)*(newx-x2)*(newx-x3)/denom0
      fact1 = (newx-x0)*(newx-x2)*(newx-x3)/denom1
      fact2 = (newx-x0)*(newx-x1)*(newx-x3)/denom2
      fact3 = (newx-x0)*(newx-x1)*(newx-x2)/denom3
      
      ynew = y0*fact0 + y1*fact1 + y2*fact2 + y3*fact3

      return
      end subroutine





      subroutine insert(x,y,alf)
!
!     inserts a points if the angle that two consecutive points make
!     with the center of the spiral is bigger than a specified value
!     (dble prec)
!
      use params
      integer j,k,n,j1,j2,jm1,k1,nt
      real*8 x(0:numt_max-1),y(0:numt_max-1),alf(0:numt_max-1),&
            newalf,newx,newy,asq,bsq,csq,cosalf,x0,y0,&
            denom0,denom1,denom2,denom3,fact0,fact1,fact2,fact3
      real*8 :: cutoff

      integer,save :: jctr=1
      real*8 :: epsd=.01  ! .1**2
      cutoff=cos(pi/30)

      n=numt-1


      call fdjctr(x,y,n,jctr)
!      jctr = 0
      j = jctr+3
      x0 = x(jctr)
      y0 = y(jctr)
      x(n+1)   =  x(n-1)
      y(n+1)   = -y(n-1)
      alf(n+1) = 2*alf(n)-alf(n-1)

      do 30 while (j.le.n-1)
         j1 = j+1
         j2 = j+2
         jm1 = j-1

         asq = (x(j1) - x(j))**2 + (y(j1) - y(j))**2
         bsq = (x(j1) - x0)**2 + (y(j1) - y0)**2
         csq = (x(j)  - x0)**2 + (y(j)  - y0)**2
         cosalf = (bsq + csq - asq) / (2*sqrt(bsq*csq))

!     insert points if alfa is too small

      if (( cosalf.lt.cutoff ).or.( asq.gt.epsd ) ) then
          if (numt+1>numt_max) then
             call abort("error: tracer insertion: array too small")
          endif
#if 0
         print*,' jinsert = ',j,x(j),y(j)
         if ( asq.gt.epsd ) write(*,'(a,2f10.6)')&
            'asq,eps  ',sqrt(asq),sqrt(epsd)
         write(*,'(6e15.3)')cosalf,cutoff,x(0),y(0),x(n),y(n)
         write(*,'(6e15.3)') bsq,csq
#endif


         newalf = (alf(j1)+alf(j))/2

         denom0 = (alf(jm1)-alf(j))*(alf(jm1)-alf(j1))*&
                 (alf(jm1)-alf(j2))
         denom1 = (alf(j)-alf(jm1))*(alf(j)-alf(j1))*&
                 (alf(j)-alf(j2))
         denom2 = (alf(j1)-alf(j))*(alf(j1)-alf(jm1))*&
                 (alf(j1)-alf(j2))
         denom3 = (alf(j2)-alf(j))*(alf(j2)-alf(j1))*&
                 (alf(j2)-alf(jm1))

         fact0 = (newalf - alf(j))*(newalf-alf(j1))*&
                 (newalf-alf(j2))/denom0
         fact1 = (newalf-alf(jm1))*(newalf-alf(j1))*&
                 (newalf-alf(j2))/denom1
         fact2 = (newalf-alf(j))*(newalf-alf(jm1))*&
                 (newalf-alf(j2))/denom2
         fact3 = (newalf-alf(j))*(newalf-alf(j1))*&
                 (newalf-alf(jm1))/denom3

         newx = x(jm1)*fact0 + x(j)*fact1 + x(j1)*fact2 &
                                            + x(j2)*fact3
         newy = y(jm1)*fact0 + y(j)*fact1 + y(j1)*fact2 &
                                            + y(j2)*fact3


         do 20 k = n+1,j1,-1
            k1 = k + 1
            alf(k1) = alf(k)
            x(k1)     = x(k)
            y(k1)     = y(k)
20       continue

         alf(j1) = newalf
         x(j1)     = newx
         y(j1)     = newy

         n = n+1
         j = j1
      endif

      j = j+1
30    continue

      numt=n+1
      return
      end subroutine


      subroutine fdjctr(x,y,n,jctr)
!
!     Finds jctr, where  (x(jctr),y(jctr)) is the inflection
!     point of the curve
!
      implicit none
      integer n,jctr
      real*8 x(0:*),y(0:*)
      real*8 x0,x1,y0,y1,cross

!     Find curvature at j = jctr (>=1)

      x0 = x(jctr-1) - x(jctr)
      y0 = y(jctr-1) - y(jctr)
      x1 = x(jctr+1) - x(jctr)
      y1 = y(jctr+1) - y(jctr)

      cross = x0*y1 - y0*x1
      if (cross.lt.0) then
         do 10 while ( (cross.lt.0.).and.(jctr.le.(n-2)) )
            x0 = -x1
            y0 = -y1
            jctr = jctr + 1
            x1 = x(jctr+1) - x(jctr)
            y1 = y(jctr+1) - y(jctr)
            cross = x0*y1 - y0*x1
10       continue
      else
         do 15 while ( (cross.gt.0.).and.(jctr.ge.2) )
            x1 = -x0
            y1 = -y0
            jctr = jctr - 1
            x0 = x(jctr-1) - x(jctr)
            y0 = y(jctr-1) - y(jctr)
            cross = x0*y1 - y0*x1
15       continue
      endif
!      print*,'jctr = ',jctr

      return
      end subroutine






end module