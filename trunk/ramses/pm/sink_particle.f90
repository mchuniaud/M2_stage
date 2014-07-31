!################################################################
!################################################################
!################################################################
!################################################################
subroutine create_sink
  use amr_commons
  use pm_commons
  use hydro_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------------
  ! sink creation routine
  ! -runs after clumpfinder
  ! -locations for sink formation have been flagged (flag2)
  ! -The global sink variables are initialized, gas is accreted from the hostcell only.
  ! -One true RAMSES particle is created 
  ! -Sink cloud particles are created
  ! -Cloud particles are scattered to grid
  ! -Accretion routine is called
  !----------------------------------------------------------------------------

  integer::ilevel,ivar,isink
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v,scale_m

  if(verbose)write(*,*)' Entering create_sink'

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  ! Merge all particles to level 1
  do ilevel=levelmin-1,1,-1
     call merge_tree_fine(ilevel)
  end do
  
  ! Remove all particle clouds around old sinks (including the central one)
  call kill_entire_cloud(1) 
  
  ! !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!  
  ! DO NOT MODIFY FLAG2 BETWEEN CLUMP_FINDER AND MAKE_SINK_FROM_CLUMP
  ! !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
  ! Run the clump finder,(produce no output, keep clump arrays allocated)
  call clump_finder(.false.,.true.)

  ! trim clumps down to R_accretion ball around peaks 
  call trim_clumps
  
  ! compute simple additive quantities and means (1st moments)
  call compute_clump_properties(uold(1,1))
  
  ! compute quantities relative to mean (2nd moments)
  call compute_clump_properties_round2(uold(1,1),.false.)
  
  ! apply all checks and flag cells for sink formation
  call flag_formation_sites
  ! Create new sink particles if relevant
  do ilevel=levelmin,nlevelmax
     call make_sink_from_clump(ilevel)
  end do

  ! Deallocate clump finder arrays
  deallocate(npeaks_per_cpu)
  deallocate(ipeak_start)
  if (ntest>0)then
     deallocate(icellp)
     deallocate(levp)
     deallocate(testp_sort)
     deallocate(imaxp)
  endif
  call deallocate_all
  ! !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ! !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !merge sinks - for star formation runs
  if (merging_scheme == 'timescale')call merge_star_sink
  
  ! Create only the central cloud particle for all sinks (old and new)
  call create_part_from_sink
  
  ! Merge sink using FOF - for smbh runs 
  if (smbh)call merge_sink(1)

  ! Create new particle clouds
  call create_cloud(1)

  ! Scatter particle to the grid                                                               
  do ilevel=1,nlevelmax
     call make_tree_fine(ilevel)
     call kill_tree_fine(ilevel)
     call virtual_tree_fine(ilevel)
  end do
  
  ! Perform first accretion or compute Bondi parameters, 
  ! gather particles to levelmin
  do ilevel=nlevelmax,levelmin,-1
     call grow_sink(ilevel,.true.)
     call collect_acczone_avg(ilevel)
     call merge_tree_fine(ilevel)
  end do

  ! Update hydro quantities for split cells
  if(hydro)then
     do ilevel=nlevelmax,levelmin,-1
        call upload_fine(ilevel)
        do ivar=1,nvar
           call make_virtual_fine_dp(uold(1,ivar),ilevel)
        end do
        ! Update boundaries 
        if(simple_boundary)call make_boundary_hydro(ilevel)
     end do
  end if

  ! Update the cloud particle properties at levelmin
  call update_cloud(levelmin)

  !effective accretion rate during last coarse step
  acc_rate(1:nsink)=acc_rate(1:nsink)/dtnew(levelmin)
  ! ir_eff and 5 are ratio of infalling energy which is radiated and protostellar radius
  if(ir_feedback)acc_lum(1:nsink)=ir_eff*acc_rate(1:nsink)*msink(1:nsink)/(5*6.955d10/scale_l)

  ! Compute new accretion rates
  call compute_accretion_rate(.true.)
  
  ! Do AGN feedback
  if(agn)call agn_feedback
     
end subroutine create_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine create_part_from_sink
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------
  ! Description: This subroutine create true RAMSES particles from the list
  ! of sink particles and stores them at level 1.
  !----------------------------------------------------------------------

  integer ::i,icpu,index_sink,isink,indp
  integer ::ntot,ntot_all,info
  logical ::ok_free
  real(dp),dimension(1:nvector,1:ndim)::xs
  integer ,dimension(1:nvector)::ind_grid,ind_part,cc
  logical ,dimension(1:nvector)::ok_true
  integer ,dimension(1:ncpu)::ntot_sink_cpu,ntot_sink_all 
  logical, dimension(1:nsinkmax)::dir_sink
  dir_sink=.false.
  ok_true=.true.

  if(numbtot(1,1)==0) return
  if(.not. hydro)return
  if(ndim.ne.3)return

  if(verbose)write(*,*)' Entering create_part_from_sink'

#if NDIM==3

  ntot=0
  ! Loop over sinks and count the ones on cpu
  do isink=1,nsink
     xs(1,1:ndim)=xsink(isink,1:ndim)
     call cmp_cpumap(xs,cc,1)
     if(cc(1).eq.myid)ntot=ntot+1
  end do

  !---------------------------------
  ! Check for free particle memory
  !--------------------------------
  ok_free=(numbp_free-ntot*ncloud_sink)>=0
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(numbp_free,numbp_free_tot,1,MPI_INTEGER,MPI_MIN,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  numbp_free_tot=numbp_free
#endif
   if(.not. ok_free)then
      write(*,*)'No more free memory for particles'
      write(*,*)'New sink particles',ntot
      write(*,*)'Increase npartmax'
#ifndef WITHOUTMPI
      call MPI_ABORT(MPI_COMM_WORLD,1,info)
#endif
#ifdef WITHOUTMPI
      stop
#endif
   end if
   
  !---------------------------------
  ! Compute global sink statistics
  !---------------------------------
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ntot,ntot_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  ntot_all=ntot
#endif
#ifndef WITHOUTMPI
  ntot_sink_cpu=0; ntot_sink_all=0
  ntot_sink_cpu(myid)=ntot
  call MPI_ALLREDUCE(ntot_sink_cpu,ntot_sink_all,ncpu,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
  ntot_sink_cpu(1)=ntot_sink_all(1)
  do icpu=2,ncpu
     ntot_sink_cpu(icpu)=ntot_sink_cpu(icpu-1)+ntot_sink_all(icpu)
  end do
#endif

  ! Starting identity number
  if(myid==1)then
     index_sink=nsink-ntot_all
  else
     index_sink=nsink-ntot_all+ntot_sink_cpu(myid-1)
  end if

  ! Level 1 linked list
  do icpu=1,ncpu
     if(numbl(icpu,1)>0)then
        ind_grid(1)=headl(icpu,1)
     endif
  end do

  !sort the sink according to mass
  if(nsink>0)then
     do i=1,nsink
        xmsink(i)=msink(i)
     end do
     call quick_sort_dp(xmsink(1),idsink_sort(1),nsink)
  endif

  ! Loop over sinks
  do i=nsink,1,-1
     isink=idsink_sort(i)
     xs(1,1:ndim)=xsink(isink,1:ndim)
     call cmp_cpumap(xs,cc,1)

     ! Create new particles
     if(cc(1).eq.myid)then
           index_sink=index_sink+1
           ! Update linked list
           call remove_free(ind_part,1)
           call add_list(ind_part,ind_grid,ok_true,1)
           indp=ind_part(1)
           tp(indp)=tsink(isink)     ! Birth epoch
           !check wheter isink is going to be a direct force sink
           dir_sink(isink)=(msink(isink) .ge. msink_direct)
           if (dir_sink(isink))then
              mp(indp)=0.    ! Mass
           else
              mp(indp)=msink(isink)     ! Mass
           end if
           levelp(indp)=levelmin
           idp(indp)=-isink          ! Identity
           xp(indp,1)=xsink(isink,1) ! Position
           xp(indp,2)=xsink(isink,2)
           xp(indp,3)=xsink(isink,3)
           vp(indp,1)=vsink(isink,1) ! Velocity
           vp(indp,2)=vsink(isink,2)
           vp(indp,3)=vsink(isink,3)
        endif

  end do
  
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(dir_sink,direct_force_sink,nsink,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  direct_force_sink(1:nsink)=dir_sink(1:nsink)
#endif

#endif

end subroutine create_part_from_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine merge_sink(ilevel)
  use pm_commons
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel

  !------------------------------------------------------------------------
  ! This routine merges sink usink the FOF algorithm.
  ! It keeps only the group centre of mass and remove other sinks.
  !------------------------------------------------------------------------

  integer::isink,new_sink
  real(dp)::dx_loc,scale,dx_min,xx,yy,zz,rr,rmax2,rmax
  integer::igrid,jgrid,ipart,jpart,next_part
  integer::ig,ip,npart1,npart2,icpu,nx_loc
  integer::igrp,icomp,gndx,ifirst,ilast,indx
  integer,dimension(1:nvector)::ind_grid,ind_part,ind_grid_part
  integer,dimension(:),allocatable::psink,gsink
  real(dp),dimension(1:3)::xbound,skip_loc
  real(dp)::egrav,ekin,uxcom,uycom,uzcom,v2rel1,v2rel2,dx_min2

  if(numbtot(1,ilevel)==0)return
  if(nsink==0)return
  if(verbose)write(*,111)ilevel

  ! Mesh spacing in that level
  dx_loc=0.5D0**ilevel
  xbound(1:3)=(/dble(nx),dble(ny),dble(nz)/)
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp
  dx_min2=dx_min*dx_min
  rmax=dble(ir_cloud)*dx_min ! Linking length in physical units
  rmax2=rmax*rmax

  allocate(psink(1:nsink),gsink(1:nsink))
  
  !-------------------------------
  ! Merge sinks using FOF
  !-------------------------------
  do isink=1,nsink
     psink(isink)=isink
     gsink(isink)=0
  end do
  
  igrp=0
  icomp=1
  ifirst=2
  do while(icomp.le.nsink)
     gndx=psink(icomp)
     if(gsink(gndx)==0)then
        igrp=igrp+1
        gsink(gndx)=igrp
     endif
     ilast=nsink
     do while((ilast-ifirst+1)>0)
        indx=psink(ifirst)
        xx=xsink(indx,1)-xsink(gndx,1)
        if(xx>scale*xbound(1)/2.0)then
           xx=xx-scale*xbound(1)
        endif
        if(xx<-scale*xbound(1)/2.0)then
           xx=xx+scale*xbound(1)
        endif
        rr=xx**2
        yy=xsink(indx,2)-xsink(gndx,2)
        if(yy>scale*xbound(2)/2.0)then
           yy=yy-scale*xbound(2)
        endif
        if(yy<-scale*xbound(2)/2.0)then
           yy=yy+scale*xbound(2)
        endif
        rr=yy**2+rr
        zz=xsink(indx,3)-xsink(gndx,3)
        if(zz>scale*xbound(3)/2.0)then
           zz=zz-scale*xbound(3)
        endif
        if(zz<-scale*xbound(3)/2.0)then
           zz=zz+scale*xbound(3)
        endif
        rr=zz**2+rr
        if(rr.le.dx_min2)then
           egrav=msink(indx)*msink(gndx)/(rr+tiny(0.d0))
           uxcom=(msink(indx)*vsink(indx,1)+msink(gndx)*vsink(gndx,1))/(msink(indx)+msink(gndx))
           uycom=(msink(indx)*vsink(indx,2)+msink(gndx)*vsink(gndx,2))/(msink(indx)+msink(gndx))
           uzcom=(msink(indx)*vsink(indx,3)+msink(gndx)*vsink(gndx,3))/(msink(indx)+msink(gndx))
           v2rel1=(vsink(indx,1)-uxcom)**2+(vsink(indx,2)-uycom)**2+(vsink(indx,3)-uzcom)**2
           v2rel2=(vsink(gndx,1)-uxcom)**2+(vsink(gndx,2)-uycom)**2+(vsink(gndx,3)-uzcom)**2
           ekin=0.5d0*(msink(indx)*v2rel1+msink(gndx)*v2rel2)
           if(ekin.lt.egrav)then
              ifirst=ifirst+1
              gsink(indx)=igrp
           else
              psink(ifirst)=psink(ilast)
              psink(ilast)=indx
              ilast=ilast-1
           endif
        else
           psink(ifirst)=psink(ilast)
           psink(ilast)=indx
           ilast=ilast-1
        endif
     end do
     icomp=icomp+1
  end do
  new_sink=igrp

  if(myid==1)then
     write(*,*)'Number of sinks after merging',new_sink
!     do isink=1,nsink
!        write(*,'(3(I3,1x),3(1PE10.3))')isink,psink(isink),gsink(isink),xsink(isink,1:ndim)
!     end do
  endif
  
  !----------------------------------------------------
  ! Compute group centre of mass and average velocty
  !----------------------------------------------------
  xsink_new=0d0; vsink_new=0d0; msink_new=0d0; tsink_new=0d0; delta_mass_new=0d0
  oksink_all=0d0; oksink_new=0d0; idsink_all=0; idsink_new=0
  do isink=1,nsink
     igrp=gsink(isink)
     if(oksink_new(igrp)==0d0)then
        oksink_all(isink)=igrp
        oksink_new(igrp)=isink
     endif
     msink_new(igrp)=msink_new(igrp)+msink(isink)
     delta_mass_new(igrp)=delta_mass_new(igrp)+delta_mass(isink)
     if(tsink_new(igrp)==0d0)then
        tsink_new(igrp)=tsink(isink)
     else
        tsink_new(igrp)=min(tsink_new(igrp),tsink(isink))
     endif
     if(idsink_new(igrp)==0)then
        idsink_new(igrp)=idsink(isink)
     else
        idsink_new(igrp)=min(idsink_new(igrp),idsink(isink))
     endif

     xx=xsink(isink,1)-xsink(int(oksink_new(igrp)),1)
     if(xx>scale*xbound(1)/2.0)then
        xx=xx-scale*xbound(1)
     endif
     if(xx<-scale*xbound(1)/2.0)then
        xx=xx+scale*xbound(1)
     endif
     xsink_new(igrp,1)=xsink_new(igrp,1)+msink(isink)*xx
     vsink_new(igrp,1)=vsink_new(igrp,1)+msink(isink)*vsink(isink,1)
     yy=xsink(isink,2)-xsink(int(oksink_new(igrp)),2)
     if(yy>scale*xbound(2)/2.0)then
        yy=yy-scale*xbound(2)
     endif
     if(yy<-scale*xbound(2)/2.0)then
        yy=yy+scale*xbound(2)
     endif
     xsink_new(igrp,2)=xsink_new(igrp,2)+msink(isink)*yy
     vsink_new(igrp,2)=vsink_new(igrp,2)+msink(isink)*vsink(isink,2)
     zz=xsink(isink,3)-xsink(int(oksink_new(igrp)),3)
     if(zz>scale*xbound(3)/2.0)then
        zz=zz-scale*xbound(3)
     endif
     if(zz<-scale*xbound(3)/2.0)then
        zz=zz+scale*xbound(3)
     endif
     xsink_new(igrp,3)=xsink_new(igrp,3)+msink(isink)*zz
     vsink_new(igrp,3)=vsink_new(igrp,3)+msink(isink)*vsink(isink,3)
  end do
  do isink=1,new_sink
     xsink_new(isink,1)=xsink_new(isink,1)/msink_new(isink)+xsink(int(oksink_new(isink)),1)
     vsink_new(isink,1)=vsink_new(isink,1)/msink_new(isink)
     xsink_new(isink,2)=xsink_new(isink,2)/msink_new(isink)+xsink(int(oksink_new(isink)),2)
     vsink_new(isink,2)=vsink_new(isink,2)/msink_new(isink)
     xsink_new(isink,3)=xsink_new(isink,3)/msink_new(isink)+xsink(int(oksink_new(isink)),3)
     vsink_new(isink,3)=vsink_new(isink,3)/msink_new(isink)
  end do
  nsink=new_sink
  msink(1:nsink)=msink_new(1:nsink)
  tsink(1:nsink)=tsink_new(1:nsink)
  idsink(1:nsink)=idsink_new(1:nsink)
  delta_mass(1:nsink)=delta_mass_new(1:nsink)
  xsink(1:nsink,1:ndim)=xsink_new(1:nsink,1:ndim)
  vsink(1:nsink,1:ndim)=vsink_new(1:nsink,1:ndim)

  ! Periodic boundary conditions
  do isink=1,nsink
     xx=xsink(isink,1)
     if(xx<-scale*skip_loc(1))then
        xx=xx+scale*(xbound(1)-skip_loc(1))
     endif
     if(xx>scale*(xbound(1)-skip_loc(1)))then
        xx=xx-scale*(xbound(1)-skip_loc(1))
     endif
     xsink(isink,1)=xx
     yy=xsink(isink,2)
     if(yy<-scale*skip_loc(2))then
        yy=yy+scale*(xbound(2)-skip_loc(2))
     endif
     if(yy>scale*(xbound(2)-skip_loc(2)))then
        yy=yy-scale*(xbound(2)-skip_loc(2))
     endif
     xsink(isink,2)=yy
     zz=xsink(isink,3)
     if(zz<-scale*skip_loc(3))then
        zz=zz+scale*(xbound(3)-skip_loc(3))
     endif
     if(zz>scale*(xbound(3)-skip_loc(3)))then
        zz=zz-scale*(xbound(3)-skip_loc(3))
     endif
     xsink(isink,3)=zz
  enddo

  deallocate(psink,gsink)
  
  !-----------------------------------------------------
  ! Remove sink particles that are part of a FOF group.
  !-----------------------------------------------------
  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0
        
        ! Count sink particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif
        
        ! Gather sink particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              if(ip==nvector)then
                 call kill_sink(ind_part,ind_grid_part,ip)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if

        igrid=next(igrid)   ! Go to next grid
     end do

     ! End loop over grids
     if(ip>0)call kill_sink(ind_part,ind_grid_part,ip)
  end do 
  ! End loop over cpus

111 format('   Entering merge_sink for level ',I2)

end subroutine merge_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine kill_sink(ind_part,ind_grid_part,np)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::np
  integer,dimension(1:nvector)::ind_grid_part,ind_part
  !-----------------------------------------------------------------------
  ! This routine is called by subroutine merge_sink
  ! It removes sink particles that are part of a FOF group.
  !-----------------------------------------------------------------------
  integer::j,isink,isink_new

  ! Particle-based arrays
  logical ,dimension(1:nvector)::ok

  do j=1,np
     isink=-idp(ind_part(j))
     ok(j)=(oksink_all(isink)==0)
     if(.not. ok(j))then
        isink_new=int(oksink_all(isink))
        idp(ind_part(j))=-isink_new
        mp(ind_part(j))=msink(isink_new)
        xp(ind_part(j),1)=xsink(isink_new,1)
        vp(ind_part(j),1)=vsink(isink_new,1)
        xp(ind_part(j),2)=xsink(isink_new,2)
        vp(ind_part(j),2)=vsink(isink_new,2)
        xp(ind_part(j),3)=xsink(isink_new,3)
        vp(ind_part(j),3)=vsink(isink_new,3)
     endif
  end do

  ! Remove particles from parent linked list
  call remove_list(ind_part,ind_grid_part,ok,np)
  call add_free_cond(ind_part,ok,np)

end subroutine kill_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine create_cloud(ilevel)
  use pm_commons
  use amr_commons
  implicit none

  integer::ilevel
  !------------------------------------------------------------------------
  ! This routine creates a cloud of test particle around each sink particle.
  ! Currently only one sink is sended to mk_cloud in order to preserve 
  ! mass ordering within the cloud particles
  !------------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,npart1,npart2,icpu
  integer,dimension(1:nvector)::ind_grid,ind_part,ind_grid_part

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Gather sink particles only.
  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0
        
        ! Count sink particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif
        
        ! Gather sink particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              !      if(ip==nvector)then !changed in order to preserve mass ordering
              if(ip==1)then
                 call mk_cloud(ind_grid,ind_part,ind_grid_part,ip,ilevel)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do

     ! End loop over grids
     if(ip>0)call mk_cloud(ind_grid,ind_part,ind_grid_part,ip,ilevel)
  end do 
  ! End loop over cpus

111 format('   Entering create_cloud for level ',I2)

end subroutine create_cloud
!################################################################
!################################################################
!################################################################
!################################################################
subroutine mk_cloud(ind_grid,ind_part,ind_grid_part,np,ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::np,ilevel
  integer,dimension(1:nvector)::ind_grid_part,ind_part
  integer,dimension(1:nvector)::ind_grid

  !-----------------------------------------------------------------------
  ! This routine is called by subroutine create_cloud. It produces 
  ! the next nvector particles
  !-----------------------------------------------------------------------

  integer::j,isink,ii,jj,kk,nx_loc
  real(dp)::dx_loc,scale,dx_min,xx,yy,zz,rr,rmax,rmass
  integer ,dimension(1:nvector)::ind_cloud,grid_index
  logical ,dimension(1:nvector)::ok_true
  ok_true=.true.

  grid_index(1:np)=ind_grid(ind_grid_part(1:np))

  ! Mesh spacing in that level
  dx_loc=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp

  rmax=dble(ir_cloud)*dx_min
  rmass=dble(ir_cloud_massive)*dx_min
  xx=0.0; yy=0.0;zz=0.0
  
  do kk=-2*ir_cloud,2*ir_cloud
     zz=dble(kk)*dx_min/2.0
     do jj=-2*ir_cloud,2*ir_cloud
        yy=dble(jj)*dx_min/2.0
        do ii=-2*ir_cloud,2*ir_cloud
           xx=dble(ii)*dx_min/2.0
           rr=sqrt(xx*xx+yy*yy+zz*zz)
           if(rr>0.and.rr<=rmax)then
              call remove_free(ind_cloud,np)
              call add_list(ind_cloud,grid_index,ok_true,np)
              do j=1,np
                 isink=-idp(ind_part(j))
                 idp(ind_cloud(j))=-isink
                 levelp(ind_cloud(j))=levelmin
                 if (rr<=rmass .and. (.not. direct_force_sink(isink)))then
                    mp(ind_cloud(j))=msink(isink)/dble(ncloud_sink_massive)
                 else
                    mp(ind_cloud(j))=0.
                 end if
                 xp(ind_cloud(j),1)=xp(ind_part(j),1)+xx
                 vp(ind_cloud(j),1)=vsink(isink,1)
                 xp(ind_cloud(j),2)=xp(ind_part(j),2)+yy
                 vp(ind_cloud(j),2)=vsink(isink,2)
                 xp(ind_cloud(j),3)=xp(ind_part(j),3)+zz
                 vp(ind_cloud(j),3)=vsink(isink,3)
              end do
           end if
        end do
     end do
  end do

  ! Reduce sink particle mass
  do j=1,np
     isink=-idp(ind_part(j))
     if (.not. direct_force_sink(isink))then
        mp(ind_part(j))=msink(isink)/dble(ncloud_sink_massive)
     end if
     vp(ind_part(j),1)=vsink(isink,1)
     vp(ind_part(j),2)=vsink(isink,2)
     vp(ind_part(j),3)=vsink(isink,3)
  end do


end subroutine mk_cloud
!################################################################
!################################################################
!################################################################
!################################################################
subroutine kill_entire_cloud(ilevel)
  use pm_commons
  use amr_commons
  implicit none
  integer::ilevel
  !------------------------------------------------------------------------
  ! This routine removes cloud particles (including the central one).
  !------------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part
  integer::ig,ip,npart1,npart2,icpu
  integer,dimension(1:nvector)::ind_grid,ind_part,ind_grid_part
  logical,dimension(1:nvector)::ok=.true.

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel
  ! Gather sink and cloud particles.
  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0        
        ! Count sink and cloud particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif        
        ! Gather sink and cloud particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              if(ip==nvector)then
                 call remove_list(ind_part,ind_grid_part,ok,ip)
                 call add_free_cond(ind_part,ok,ip)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        
        igrid=next(igrid)   ! Go to next grid
     end do
     
     ! End loop over grids
     if(ip>0)then
        call remove_list(ind_part,ind_grid_part,ok,ip)
        call add_free_cond(ind_part,ok,ip)
     end if
  end do
111 format('   Entering kill_cloud for level ',I2)
end subroutine kill_entire_cloud
!################################################################
!################################################################
!################################################################
!################################################################
subroutine collect_acczone_avg(ilevel)
  use pm_commons
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel

  !------------------------------------------------------------------------
  ! This routine is used to collect all relevant information to compute the 
  ! the accretion rate. The information is collected level-by-level when
  ! going down in the call tree (leafs at the bottom), while accretion is 
  ! performed on the way up.
  ! Bondi case:
  ! - compute accretion kernel size based on central cell properties (bondi_velocity)
  ! - compute properties inside accretion zone and use kernel function for weighting (bondi_average)
  ! Flux case:
  ! - Loop over cloud parts to compute divergence of rho*v
  !------------------------------------------------------------------------

  integer::igrid,jgrid,ipart,jpart,next_part,info,ind,jlevel
  integer::ig,ip,npart1,npart2,icpu,nx_loc,isink
  integer,dimension(1:nvector)::cc,cell_index,cell_levl,ind_grid,ind_part,ind_grid_part
  real(dp),dimension(1:nvector,1:3)::xpart
  real(dp)::dx_loc,dx_min,scale,factG
  real(dp),dimension(1:nsinkmax)::divs, divs_tot
  character(LEN=15)::action

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel
  action='count'
  call count_clouds(ilevel,action)

  call make_virtual_reverse_int(flag2(1),ilevel)
  call make_virtual_fine_int(flag2(1),ilevel)

  action='weight'
  call count_clouds(ilevel,action)
  
  level_sink_new(1:nsinkmax,ilevel)=.false.

  ! Gravitational constant
  factG=1d0
  if(cosmo)factG=3d0/8d0/3.1415926*omega_m*aexp

  ! Mesh spacing in that level
  dx_loc=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp

  ! Reset new sink variables
  v2sink_new=0d0; c2sink_new=0d0; oksink_new=0d0
  divs=0d0; divs_tot=0d0

  !use flag2 to count the cloud particles per cell
  !to handle accretion onto multiple sinks from one cell
  flag2=0

  ! Loop over sink particles. pass them one-by-one to bond velocity
  !only the central sink particles (not cloud) are used to compute bondi_velocity
  do isink=1,nsink
     ind_part(1)=isink
     xpart(1,1:ndim)=xsink(isink,1:ndim)
     call cmp_cpumap(xpart,cc,1)
     if(cc(1)==myid)then
        call get_cell_index(cell_index,cell_levl,xpart,nlevelmax,1)
        ind=(cell_index(1)-ncoarse-1)/ngridmax+1 ! cell position                                                                
        ind_grid(1)=cell_index(1)-ncoarse-(ind-1)*ngridmax ! grid index                                                        
        jlevel=cell_levl(1)
        call bondi_velocity(ind_grid,ind_part,jlevel)
     end if
  end do
  
  if(nsink>0)then
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(oksink_new,oksink_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(c2sink_new,c2sink_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(v2sink_new,v2sink_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
#else
     oksink_all=oksink_new
     c2sink_all=c2sink_new
     v2sink_all=v2sink_new
#endif
  endif
  do isink=1,nsink
     if(oksink_all(isink)==1d0)then
        c2sink(isink)=c2sink_all(isink)
        v2sink(isink)=v2sink_all(isink)

        !Krumholz sets the kernel size based on the estimate of the bondi radius - 
        ! r2sink(isink)=(factG*msink(isink)/(v2sink(isink)+c2sink(isink)))**2
        !enforce dx_min/4 < "scale_radius" < 2*dx_min
        ! r2k(isink)=min(max(r2sink(isink),(dx_min/4.0)**2),(ir_cloud*dx_min/2.)**2)

        !fix kernel size to half the sink size
        r2k(isink)=(ir_cloud*dx_min/2.)**2
     endif
  end do



  ! Gather sink and cloud particles.
  wden=0d0; wvol=0d0; weth=0d0; wmom=0d0

  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0
        
        ! Count sink and cloud particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif
        
        ! Gather sink and cloud particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              if(ip==nvector)then
                 call bondi_average(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)
                 call divergence_sink(ind_part,divs,ip)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do

     ! End loop over grids
     if(ip>0)then
        call bondi_average(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)
        call divergence_sink(ind_part,divs,ip)
     end if
  end do
  ! End loop over cpus

  if(nsink>0)then
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(wden,wden_new,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(wvol,wvol_new,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(weth,weth_new,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(wmom,wmom_new,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(divs,divs_tot,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(level_sink_new,level_sink,nsinkmax*(nlevelmax-levelmin+1),MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,info)
#else
     wden_new=wden
     wvol_new=wvol
     weth_new=weth
     wmom_new=wmom
     divs_tot=divs
     level_sink=level_sink_new
#endif
  endif
  do isink=1,nsink
     weighted_density(isink,ilevel)=wden_new(isink)
     weighted_volume(isink,ilevel)=wvol_new(isink)
     weighted_momentum(isink,ilevel,1:ndim)=wmom_new(isink,1:ndim)
     weighted_ethermal(isink,ilevel)=weth_new(isink)
     divsink(isink,ilevel)=divs_tot(isink)
  end do

111 format('   Entering bondi_hoyle for level ',I2)

end subroutine collect_acczone_avg
!################################################################
!################################################################
!################################################################
!################################################################
subroutine bondi_velocity(ind_grid,ind_part,ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::ilevel
  integer,dimension(1:nvector)::ind_grid,ind_part

  !-----------------------------------------------------------------------
  ! This routine is called by subroutine bondi_hoyle.
  ! It computes the gas velocity and sound speed in the cell
  ! each sink particle sits in.
  !-----------------------------------------------------------------------

  integer::idim,nx_loc,isink
  real(dp)::v2,c2,d,u,v,w,e
  real(dp)::dx,dx_loc,scale,vol_loc
  logical::error
#ifdef SOLVERmhd
  real(dp)::bx1,bx2,by1,by2,bz1,bz2
#endif
  ! Grid based quantities
  real(dp),dimension(1:ndim)::x0
  integer ,dimension(1:nvector)::ind_cell
  integer ,dimension(1:nvector,1:threetondim)::nbors_father_cells
  integer ,dimension(1:nvector,1:twotondim)::nbors_father_grids
  ! Particle based quantities
  logical::ok
  real(dp),dimension(1:ndim)::x,skip_loc
  integer ,dimension(1:ndim)::id,igd,icd
  integer::igrid,icell,indp,kg

#if NDIM==3
  ! Mesh spacing in that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim



  ! Lower left corner of 3x3x3 grid-cube
  do idim=1,ndim
     x0(idim)=xg(ind_grid(1),idim)-3.0D0*dx
  end do

  ! Gather 27 neighboring father cells (should be present anytime !)
  ind_cell(1)=father(ind_grid(1))
  call get3cubefather(ind_cell,nbors_father_cells,nbors_father_grids,1,ilevel)

  ! Rescale position at level ilevel
  do idim=1,ndim
        x(idim)=xsink(ind_part(1),idim)/scale+skip_loc(idim)
        x(idim)=x(idim)-x0(idim)
        x(idim)=x(idim)/dx
  end do

  ! Check for illegal moves
  error=.false.
  do idim=1,ndim
     if(x(idim)<=0.0D0.or.x(idim)>=6.0D0)error=.true.
    end do
  if(error)then
     write(*,*)'problem in bondi_velocity'
     write(*,*)ilevel,x(1:3)
     stop
  end if

  ! NGP at level ilevel
  do idim=1,ndim
     id(idim)=int(x(idim))
     ! Compute parent grids
     igd(idim)=id(idim)/2
  end do

  kg=1+igd(1)+3*igd(2)+9*igd(3)
  igrid=son(nbors_father_cells(1,kg))
  
  ! Check if particles are entirely in level ilevel
  ok=(igrid>0)

  if(ok)then
     
     ! Compute parent cell position
     do idim=1,ndim
        icd(idim)=id(idim)-2*igd(idim)
     end do
     icell=1+icd(1)+2*icd(2)+4*icd(3)
     
     ! Compute parent cell adress
     indp=ncoarse+(icell-1)*ngridmax+igrid
  
     ! Gather hydro variables
     d=uold(indp,1)
     u=uold(indp,2)/d
     v=uold(indp,3)/d
     w=uold(indp,4)/d
     e=uold(indp,5)/d
#ifdef SOLVERmhd
     bx1=uold(indp,6)
     by1=uold(indp,7)
     bz1=uold(indp,8)
     bx2=uold(indp,nvar+1)
     by2=uold(indp,nvar+2)
     bz2=uold(indp,nvar+3)
     e=e-0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
     v2=(u**2+v**2+w**2)
     e=e-0.5d0*v2
!     c2=MAX(gamma*(gamma-1.0)*e,smallc**2)
     c2=MAX((gamma-1.0)*e,smallc**2)
     isink=ind_part(1)
     v2=(u-vsink(isink,1))**2+(v-vsink(isink,2))**2+(w-vsink(isink,3))**2
     v2sink_new(isink)=v2
     c2sink_new(isink)=c2
     oksink_new(isink)=1d0
  endif

#endif

end subroutine bondi_velocity
!################################################################
!################################################################
!################################################################
!################################################################
subroutine bondi_average(ind_grid,ind_part,ind_grid_part,ng,np,ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::ng,np,ilevel
  integer,dimension(1:nvector)::ind_grid,ind_grid_part,ind_part

  !-----------------------------------------------------------------------
  ! This routine is called by subroutine bondi_hoyle. Each cloud particle
  ! reads up the value of density, sound speed and velocity from its
  ! position in the grid by CIC.
  !-----------------------------------------------------------------------

  logical::error
  integer::i,j,ind,idim,nx_loc,isink
  real(dp)::d,u,v=0d0,w=0d0,e
  real(dp)::dx,scale,weight,r2,dx_min
#ifdef SOLVERmhd
  real(dp)::bx1,bx2,by1,by2,bz1,bz2
#endif
  ! Grid-based arrays
  real(dp),dimension(1:nvector,1:ndim)::x0
  integer ,dimension(1:nvector)::ind_cell!,cell_index,cell_lev
  integer ,dimension(1:nvector,1:threetondim)::nbors_father_cells
  integer ,dimension(1:nvector,1:twotondim)::nbors_father_grids
  ! Particle-based arrays
  logical ,dimension(1:nvector)::ok
  real(dp),dimension(1:nvector)::dgas,ugas,vgas,wgas,egas
  real(dp),dimension(1:nvector,1:ndim)::x,dd,dg!,xtest
  integer ,dimension(1:nvector,1:ndim)::ig,id,igg,igd,icg,icd
  real(dp),dimension(1:nvector,1:twotondim)::vol
  integer ,dimension(1:nvector,1:twotondim)::igrid,icell,indp,kg
  real(dp),dimension(1:3)::skip_loc

  ! usage of CIC interpolation for each cloud particle is an overkill as 
  ! one averages over cloud particles anyway.


!  do j=1,np
!     xtest(j,1:3)=xp(ind_part(j),1:3)
!  end do
!  call get_cell_index(cell_index,cell_lev,xtest,ilevel,np)

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp

  ! Lower left corner of 3x3x3 grid-cube
  do idim=1,ndim
     do i=1,ng
        x0(i,idim)=xg(ind_grid(i),idim)-3.0D0*dx
     end do
  end do

  ! Gather 27 neighboring father cells (should be present anytime !)
  do i=1,ng
     ind_cell(i)=father(ind_grid(i))
  end do
  call get3cubefather(ind_cell,nbors_father_cells,nbors_father_grids,ng,ilevel)

  ! Rescale position at level ilevel
  do idim=1,ndim
     do j=1,np
        x(j,idim)=xp(ind_part(j),idim)/scale+skip_loc(idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)-x0(ind_grid_part(j),idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)/dx
     end do
  end do

  ! Check for illegal moves
  error=.false.
  do idim=1,ndim
     do j=1,np
        if(x(j,idim)<0.5D0.or.x(j,idim)>5.5D0)error=.true.
     end do
  end do
  if(error)then
     write(*,*)'problem in average_density'
     do idim=1,ndim
        do j=1,np
           if(x(j,idim)<0.5D0.or.x(j,idim)>5.5D0)then
              write(*,*)x(j,1:ndim)
           endif
        end do
     end do
     stop
  end if

  ! CIC at level ilevel (dd: right cloud boundary; dg: left cloud boundary)
  do idim=1,ndim
     do j=1,np
        dd(j,idim)=x(j,idim)+0.5D0
        id(j,idim)=int(dd(j,idim))
        dd(j,idim)=dd(j,idim)-id(j,idim)
        dg(j,idim)=1.0D0-dd(j,idim)
        ig(j,idim)=id(j,idim)-1
     end do
  end do

   ! Compute parent grids
  do idim=1,ndim
     do j=1,np
        igg(j,idim)=ig(j,idim)/2
        igd(j,idim)=id(j,idim)/2
     end do
  end do
#if NDIM==1
  do j=1,np
     kg(j,1)=1+igg(j,1)
     kg(j,2)=1+igd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     kg(j,1)=1+igg(j,1)+3*igg(j,2)
     kg(j,2)=1+igd(j,1)+3*igg(j,2)
     kg(j,3)=1+igg(j,1)+3*igd(j,2)
     kg(j,4)=1+igd(j,1)+3*igd(j,2)
  end do
#endif
#if NDIM==3
  do j=1,np
     kg(j,1)=1+igg(j,1)+3*igg(j,2)+9*igg(j,3)
     kg(j,2)=1+igd(j,1)+3*igg(j,2)+9*igg(j,3)
     kg(j,3)=1+igg(j,1)+3*igd(j,2)+9*igg(j,3)
     kg(j,4)=1+igd(j,1)+3*igd(j,2)+9*igg(j,3)
     kg(j,5)=1+igg(j,1)+3*igg(j,2)+9*igd(j,3)
     kg(j,6)=1+igd(j,1)+3*igg(j,2)+9*igd(j,3)
     kg(j,7)=1+igg(j,1)+3*igd(j,2)+9*igd(j,3)
     kg(j,8)=1+igd(j,1)+3*igd(j,2)+9*igd(j,3)
  end do
#endif
  do ind=1,twotondim
     do j=1,np
        igrid(j,ind)=son(nbors_father_cells(ind_grid_part(j),kg(j,ind)))
     end do
  end do

  ! Check if particles are entirely in level ilevel
  ok(1:np)=.true.
  do ind=1,twotondim
     do j=1,np
        ok(j)=ok(j).and.igrid(j,ind)>0
     end do
  end do

  ! If not, rescale position at level ilevel-1
  do idim=1,ndim
     do j=1,np
        if(.not.ok(j))then
           x(j,idim)=x(j,idim)/2.0D0
        end if
     end do
  end do
  ! If not, redo CIC at level ilevel-1
  do idim=1,ndim
     do j=1,np
        if(.not.ok(j))then
           dd(j,idim)=x(j,idim)+0.5D0
           id(j,idim)=int(dd(j,idim))
           dd(j,idim)=dd(j,idim)-id(j,idim)
           dg(j,idim)=1.0D0-dd(j,idim)
           ig(j,idim)=id(j,idim)-1
        end if
     end do
  end do

 ! Compute parent cell position
  do idim=1,ndim
     do j=1,np
        if(ok(j))then
           icg(j,idim)=ig(j,idim)-2*igg(j,idim)
           icd(j,idim)=id(j,idim)-2*igd(j,idim)
        else
           icg(j,idim)=ig(j,idim)
           icd(j,idim)=id(j,idim)
        end if
     end do
  end do
#if NDIM==1
  do j=1,np
     icell(j,1)=1+icg(j,1)
     icell(j,2)=1+icd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     if(ok(j))then
        icell(j,1)=1+icg(j,1)+2*icg(j,2)
        icell(j,2)=1+icd(j,1)+2*icg(j,2)
        icell(j,3)=1+icg(j,1)+2*icd(j,2)
        icell(j,4)=1+icd(j,1)+2*icd(j,2)
     else
        icell(j,1)=1+icg(j,1)+3*icg(j,2)
        icell(j,2)=1+icd(j,1)+3*icg(j,2)
        icell(j,3)=1+icg(j,1)+3*icd(j,2)
        icell(j,4)=1+icd(j,1)+3*icd(j,2)
     end if
  end do
#endif
#if NDIM==3
  do j=1,np
     if(ok(j))then
        icell(j,1)=1+icg(j,1)+2*icg(j,2)+4*icg(j,3)
        icell(j,2)=1+icd(j,1)+2*icg(j,2)+4*icg(j,3)
        icell(j,3)=1+icg(j,1)+2*icd(j,2)+4*icg(j,3)
        icell(j,4)=1+icd(j,1)+2*icd(j,2)+4*icg(j,3)
        icell(j,5)=1+icg(j,1)+2*icg(j,2)+4*icd(j,3)
        icell(j,6)=1+icd(j,1)+2*icg(j,2)+4*icd(j,3)
        icell(j,7)=1+icg(j,1)+2*icd(j,2)+4*icd(j,3)
        icell(j,8)=1+icd(j,1)+2*icd(j,2)+4*icd(j,3)
     else
        icell(j,1)=1+icg(j,1)+3*icg(j,2)+9*icg(j,3)
        icell(j,2)=1+icd(j,1)+3*icg(j,2)+9*icg(j,3)
        icell(j,3)=1+icg(j,1)+3*icd(j,2)+9*icg(j,3)
        icell(j,4)=1+icd(j,1)+3*icd(j,2)+9*icg(j,3)
        icell(j,5)=1+icg(j,1)+3*icg(j,2)+9*icd(j,3)
        icell(j,6)=1+icd(j,1)+3*icg(j,2)+9*icd(j,3)
        icell(j,7)=1+icg(j,1)+3*icd(j,2)+9*icd(j,3)
        icell(j,8)=1+icd(j,1)+3*icd(j,2)+9*icd(j,3)   
     end if
  end do
#endif
        
  ! Compute parent cell adresses
  do ind=1,twotondim
     do j=1,np
        if(ok(j))then
           indp(j,ind)=ncoarse+(icell(j,ind)-1)*ngridmax+igrid(j,ind)
        else
           indp(j,ind)=nbors_father_cells(ind_grid_part(j),icell(j,ind))
        end if
     end do
  end do

  ! Compute cloud volumes
#if NDIM==1
  do j=1,np
     vol(j,1)=dg(j,1)
     vol(j,2)=dd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     vol(j,1)=dg(j,1)*dg(j,2)
     vol(j,2)=dd(j,1)*dg(j,2)
     vol(j,3)=dg(j,1)*dd(j,2)
     vol(j,4)=dd(j,1)*dd(j,2)
  end do
#endif
#if NDIM==3
  do j=1,np
     vol(j,1)=dg(j,1)*dg(j,2)*dg(j,3)
     vol(j,2)=dd(j,1)*dg(j,2)*dg(j,3)
     vol(j,3)=dg(j,1)*dd(j,2)*dg(j,3)
     vol(j,4)=dd(j,1)*dd(j,2)*dg(j,3)
     vol(j,5)=dg(j,1)*dg(j,2)*dd(j,3)
     vol(j,6)=dd(j,1)*dg(j,2)*dd(j,3)
     vol(j,7)=dg(j,1)*dd(j,2)*dd(j,3)
     vol(j,8)=dd(j,1)*dd(j,2)*dd(j,3)
  end do
#endif

  dgas(1:np)=0.0D0  ! Gather gas density
  ugas(1:np)=0.0D0  ! Gather gas x-momentum (velocity ?)
  vgas(1:np)=0.0D0  ! Gather gas y-momentum (velocity ?)
  wgas(1:np)=0.0D0  ! Gather gas z-momentum (velocity ?)
  egas(1:np)=0.0D0  ! Gather gas thermal energy (specific ?)

  ! ROM to AJC: if you want, replace below vol(j,ind) by 1./twotondim
  do ind=1,twotondim
     do j=1,np
        d=uold(indp(j,ind),1)
        u=uold(indp(j,ind),2)/d
        v=uold(indp(j,ind),3)/d
        w=uold(indp(j,ind),4)/d
        e=uold(indp(j,ind),5)/d
#ifdef SOLVERmhd
        bx1=uold(indp(j,ind),6)
        by1=uold(indp(j,ind),7)
        bz1=uold(indp(j,ind),8)
        bx2=uold(indp(j,ind),nvar+1)
        by2=uold(indp(j,ind),nvar+2)
        bz2=uold(indp(j,ind),nvar+3)
        e=e-0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
        e=e-0.5*(u*u+v*v+w*w)
        dgas(j)=dgas(j)+d*vol(j,ind)
        ugas(j)=ugas(j)+d*u*vol(j,ind)
        vgas(j)=vgas(j)+d*v*vol(j,ind)
        wgas(j)=wgas(j)+d*w*vol(j,ind)
        egas(j)=egas(j)+d*e*vol(j,ind)
     end do
  end do


  do j=1,np
     isink=-idp(ind_part(j))
     weight=weightp(ind_part(j))
     wden(isink)=wden(isink)+weight*dgas(j)
     wmom(isink,1)=wmom(isink,1)+weight*ugas(j)
     wmom(isink,2)=wmom(isink,2)+weight*vgas(j)
     wmom(isink,3)=wmom(isink,3)+weight*wgas(j)
     weth(isink)=weth(isink)+weight*egas(j)
     wvol(isink)=wvol(isink)+weight
     ! check wether sink has clouds in current level
     if(ok(j))then
        level_sink_new(isink,ilevel)=.true.
     else
        level_sink_new(isink,ilevel-1)=.true.
     end if
  end do

end subroutine bondi_average
!################################################################
!################################################################
!################################################################
!################################################################
subroutine grow_sink(ilevel,on_creation)
  use pm_commons
  use amr_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel
  logical::on_creation
  !------------------------------------------------------------------------
  ! This routine performs accretion onto the sink. It vectorizes the loop
  ! over all sink cloud particles and calls accrete_sink as soon as nvector 
  ! particles are collected
  ! -> replaces grow_bondi and grow_jeans
  !------------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part,info
  integer::ig,ip,npart1,npart2,icpu,isink,lev,nx_loc
  integer,dimension(1:nvector)::ind_grid,ind_part,ind_grid_part
  real(dp)::scale,dx_min,vol_min
  real(dp),dimension(1:ndim)::old_loc,old_vel

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=(0.5D0**nlevelmax)*scale
  vol_min=dx_min**ndim

#if NDIM==3

  ! Compute sink accretion rates
  if (.not. on_creation)call compute_accretion_rate(.false.)
  
  ! Reset new sink variables
  msink_new=0d0; xsink_new=0.d0; vsink_new=0d0; delta_mass_new=0d0; lsink_new=0d0

  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0
        ! Count sink and cloud particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif
        ! Gather sink and cloud particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              if(ip==nvector)then
                 call accrete_sink(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel,on_creation)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do
     ! End loop over grids
     if(ip>0)call accrete_sink(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel,on_creation)
  end do
  ! End loop over cpus
  if(nsink>0)then
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(msink_new,msink_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(delta_mass_new,delta_mass_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(xsink_new,xsink_all,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(vsink_new,vsink_all,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
     call MPI_ALLREDUCE(lsink_new,lsink_all,nsinkmax*3,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
#else
     msink_all=msink_new
     delta_mass_all=delta_mass_new
     xsink_all=xsink_new
     vsink_all=vsink_new
     lsink_all=lsink_new
#endif
  endif
  do isink=1,nsink
     ! Reset jump in sink coordinates
     do lev=levelmin,nlevelmax
        sink_jump(isink,1:ndim,lev)=sink_jump(isink,1:ndim,lev)-xsink(isink,1:ndim)
     end do
     
     !save old velocity and location to compute deltas
     old_loc(1:ndim)=xsink(isink,1:ndim)
     old_vel(1:ndim)=vsink(isink,1:ndim)
     
     ! Change to conservative quantities
     xsink(isink,1:ndim)=xsink(isink,1:ndim)*msink(isink)
     vsink(isink,1:ndim)=vsink(isink,1:ndim)*msink(isink)
     

     ! Accrete to sink variables
     msink(isink)=msink(isink)+msink_all(isink)
     xsink(isink,1:ndim)=xsink(isink,1:ndim)+xsink_all(isink,1:ndim)
     vsink(isink,1:ndim)=vsink(isink,1:ndim)+vsink_all(isink,1:ndim)
     !compute lsink with reference point of old xsink
     lsink(isink,1:3)=lsink(isink,1:3)+lsink_all(isink,1:3)

     
     ! Change back
     xsink(isink,1:ndim)=xsink(isink,1:ndim)/msink(isink)
     vsink(isink,1:ndim)=vsink(isink,1:ndim)/msink(isink)

     !correct for new center of mass location/velocity
     lsink(isink,1:3)=lsink(isink,1:3)-msink(isink)*cross((xsink(isink,1:ndim)-old_loc(1:ndim)),(vsink(isink,1:ndim)-old_vel(1:ndim)))

     ! Store jump in sink coordinates
     do lev=levelmin,nlevelmax
        sink_jump(isink,1:ndim,lev)=sink_jump(isink,1:ndim,lev)+xsink(isink,1:ndim)
     end do

     ! Store accreted mass
     acc_rate(isink)=acc_rate(isink)+msink_all(isink)
     delta_mass(isink)=delta_mass(isink)+delta_mass_all(isink)
  
  end do

  
#endif
111 format('   Entering grow_sink for level ',I2)

end subroutine grow_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine accrete_sink(ind_grid,ind_part,ind_grid_part,ng,np,ilevel,on_creation)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::ng,np,ilevel
  integer,dimension(1:nvector)::ind_grid
  integer,dimension(1:nvector)::ind_grid_part,ind_part
  logical::on_creation

  !-----------------------------------------------------------------------
  ! This routine is called by subroutine grow_sink. It performs accretion
  ! for nvector particles. Routine is not very efficient. Optimize if taking too long...
  !-----------------------------------------------------------------------

  integer::i,j,idim,nx_loc,isink,ivar,ind,ix,iy,iz,ii,jj,kk
  real(dp)::r2,v2,d,e,d_floor,density,volume
#ifdef SOLVERmhd
  real(dp)::bx1,bx2,by1,by2,bz1,bz2
#endif
  real(dp),dimension(1:nvar)::z
  real(dp)::factG,scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(dp)::dx,dx_loc,dx_min,scale,vol_loc,weight,acc_mass,temp,d_jeans,c2,ethermal
  logical::error
  ! Grid based arrays
  real(dp),dimension(1:nvector,1:ndim)::x0
  integer ,dimension(1:nvector)::ind_cell
  integer ,dimension(1:nvector,1:threetondim)::nbors_father_cells
  integer ,dimension(1:nvector,1:twotondim)::nbors_father_grids
  ! Particle based arrays
  logical,dimension(1:nvector)::ok
  real(dp),dimension(1:nvector,1:ndim)::x
  integer ,dimension(1:nvector,1:ndim)::id,igd,icd
  integer ,dimension(1:nvector)::igrid,icell,indp,kg
  real(dp),dimension(1:3)::skip_loc,xx,vv,xpoint
  real(dp),dimension(1:twotondim,1:3)::xc


  real(dp),dimension(1:3)::r_rel,p_acc,p_rel,p_rel_rad,p_rel_acc,p_rel_tan
  real(dp)::r_abs,boundness
  real(dp),dimension(1:3)::r_rel_s,v_rel_s
  real(dp)::e_spec,l_spec2,r_min,count_points

  logical::nolacc

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
 
#if NDIM==3

  ! Gravitational constant
  factG=1d0
  if(cosmo)factG=3d0/8d0/3.1415926*omega_m*aexp

  ! Mesh spacing in that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim
  dx_min=scale*0.5D0**nlevelmax/aexp

  ! Cells center position relative to grid center position
  do ind=1,twotondim
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     xc(ind,1)=(dble(ix)-0.5D0)*dx
     xc(ind,2)=(dble(iy)-0.5D0)*dx
     xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do

  ! Lower left corner of 3x3x3 grid-cube
  do idim=1,ndim
     do i=1,ng
        x0(i,idim)=xg(ind_grid(i),idim)-3.0D0*dx
     end do
  end do

  ! Gather 27 neighboring father cells (should be present anytime !)
  do i=1,ng
     ind_cell(i)=father(ind_grid(i))
  end do
  call get3cubefather(ind_cell,nbors_father_cells,nbors_father_grids,ng,ilevel)

  ! Rescale position at level ilevel
  do idim=1,ndim
     do j=1,np
        x(j,idim)=xp(ind_part(j),idim)/scale+skip_loc(idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)-x0(ind_grid_part(j),idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)/dx
     end do
  end do

  ! Check for illegal moves
  error=.false.
  do idim=1,ndim
     do j=1,np
        if(x(j,idim)<=0.0D0.or.x(j,idim)>=6.0D0)error=.true.
     end do
  end do
  if(error)then
     write(*,*)'problem in accrete_sink'
     write(*,*)ilevel,ng,np
     stop
  end if

  ! NGP at level ilevel
  do idim=1,ndim
     do j=1,np
        id(j,idim)=int(x(j,idim))
     end do
  end do

   ! Compute parent grids
  do idim=1,ndim
     do j=1,np
        igd(j,idim)=id(j,idim)/2
     end do
  end do
#if NDIM==1
  do j=1,np
     kg(j)=1+igd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     kg(j)=1+igd(j,1)+3*igd(j,2)
  end do
#endif
#if NDIM==3
  do j=1,np
     kg(j)=1+igd(j,1)+3*igd(j,2)+9*igd(j,3)
  end do


!bugcheck
  do j=1,np
     if (kg(j) > 27 .or. kg(j) < 1)then
        print*,'cpu ', myid, ' produced an error in accrete sink'
        print*,'kg: ',kg(j)
        print*,'igd: ',igd(j,1),igd(j,2),igd(j,3)
        print*,'id: ',id(j,1),id(j,2),id(j,3)
        print*,'x: ',x(j,1),x(j,2),x(j,3)
        print*,'x0: ',x0(j,1),x0(j,2),x0(j,3)
        print*,'xp: ',xp(ind_part(j),1:3)
        print*,'skip_loc: ',skip_loc(1:3)
        print*,'scale: ',scale
        print*,'ind_part: ',ind_part(j)
     end if
  end do


#endif
  do j=1,np
     igrid(j)=son(nbors_father_cells(ind_grid_part(j),kg(j)))
  end do

  ! Check if particles are entirely in level ilevel
  ok(1:np)=.true.
  do j=1,np
     ok(j)=ok(j).and.igrid(j)>0
  end do

  ! Compute parent cell position
  do idim=1,ndim
     do j=1,np
        if(ok(j))then
           icd(j,idim)=id(j,idim)-2*igd(j,idim)
        end if
     end do
  end do
#if NDIM==1
  do j=1,np
     if(ok(j))then
        icell(j)=1+icd(j,1)
     end if
  end do
#endif
#if NDIM==2
  do j=1,np
     if(ok(j))then
        icell(j)=1+icd(j,1)+2*icd(j,2)
     end if
  end do
#endif
#if NDIM==3
  do j=1,np
     if(ok(j))then
        icell(j)=1+icd(j,1)+2*icd(j,2)+4*icd(j,3)
     end if
  end do
#endif
        
  ! Compute parent cell adress
  do j=1,np
     if(ok(j))then
        indp(j)=ncoarse+(icell(j)-1)*ngridmax+igrid(j)
     end if
  end do

  ! Check if particles are in a leaf cell
  do j=1,np
     if(ok(j))then
        ok(j)=son(indp(j))==0
     endif
  end do
  
  ! Remove mass from hydro cells
  do j=1,np
     if(ok(j))then

        if (ilevel<nlevelmax)write(*,*),'trying to accrete from cell which is not at levelmax...'

        ! Get cell center positions
        xx(1)=(x0(ind_grid_part(j),1)+3.0D0*dx+xc(icell(j),1)-skip_loc(1))*scale
        xx(2)=(x0(ind_grid_part(j),2)+3.0D0*dx+xc(icell(j),2)-skip_loc(2))*scale
        xx(3)=(x0(ind_grid_part(j),3)+3.0D0*dx+xc(icell(j),3)-skip_loc(3))*scale


        ! Convert uold to primitive variables
        d=uold(indp(j),1)
        vv(1)=uold(indp(j),2)/d
        vv(2)=uold(indp(j),3)/d
        vv(3)=uold(indp(j),4)/d
        e=uold(indp(j),5)/d

#ifdef SOLVERmhd
        bx1=uold(indp(j),6)
        by1=uold(indp(j),7)
        bz1=uold(indp(j),8)
        bx2=uold(indp(j),nvar+1)
        by2=uold(indp(j),nvar+2)
        bz2=uold(indp(j),nvar+3)
        e=e-0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
        v2=(vv(1)**2+vv(2)**2+vv(3)**2)
        e=e-0.5d0*v2
        do ivar=imetal,nvar
           z(ivar)=uold(indp(j),ivar)/d
        end do
        
        ! Get sink index
        isink=-idp(ind_part(j))
        

        if (on_creation)then 
           if (new_born(isink))then
              ! on sink creation, new sinks
              acc_mass=sink_seedmass/ncloud_sink
              acc_mass=max(min(acc_mass,0.125*(d-d_sink)*vol_loc),1.d-10*d*vol_loc)
           else
              ! on sink creation, preexisting sinks
              acc_mass=0.         
           end if
        else           

           ! regular accretion
           weight=weightp(ind_part(j))
           
           ! Loop over level: sink cloud can overlap several levels
           density=0.d0
           volume=0.d0
           do i=levelmin,nlevelmax
              density=density+weighted_density(isink,i)
              volume=volume+weighted_volume(isink,i)
           end do
           density=density/(volume+tiny(0._dp))
           
           ! Compute accreted mass using density weighting
           acc_mass=dMsink_overdt(isink)*dtnew(ilevel)*weight/(volume+tiny(0._dp))*d/(density+tiny(0._dp))
           
           if (threshold_accretion)then
              ! User defined density threshold
              d_floor=d_sink           
              ! Jeans length related density threshold  
              if(d_sink<0.0)then
                 temp=max(e*(gamma-1.0),smallc**2)
                 d_jeans=temp*3.1415926/(4.0*dx_loc)**2/factG
                 d_floor=d_jeans
              endif
              acc_mass=c_acc*weight*(d-d_floor)
           end if
           ! No neg accretion
           acc_mass=max(acc_mass,0.0_dp)               
        end if
        
        ! momentum in relative motion
        r_rel(1:3)=xx(1:3)-xsink(isink,1:3) 
        r_abs=sum(r_rel(1:3)**2)**0.5      
        p_rel=d*vol_loc*(vv(1:3)-vsink(isink,1:3))
        p_rel_rad=sum(r_rel(1:3)*p_rel(1:3))*r_rel(1:3)/(r_abs**2+tiny(0.d0))
        p_rel_tan=p_rel-p_rel_rad

        nolacc=nol_accretion
        ! for accretion from very low density cells
        ! do accrete angular momentum (to prevent negative densities...)
!        if (.not. on_creation)then
!           if(d < 1.d-4*d_sink .or. density < 1.d-4*d_sink)nolacc=.false.
!        end if
           
        if(nolacc)then
           p_rel_acc=p_rel_rad*acc_mass/(d*vol_loc)
        else
           p_rel_acc=p_rel*acc_mass/(d*vol_loc)
        end if

        !total accreted momentum 
        p_acc=p_rel_acc+vsink(isink,1:3)*acc_mass

        !add accreted properties
        msink_new(isink)=msink_new(isink)+acc_mass
        delta_mass_new(isink)=delta_mass_new(isink)+acc_mass
        xsink_new(isink,1:3)=xsink_new(isink,1:3)+acc_mass*xx(1:3)
        vsink_new(isink,1:3)=vsink_new(isink,1:3)+p_acc(1:3)
        lsink_new(isink,1:3)=lsink_new(isink,1:3)+cross(r_rel(1:3),p_rel_acc(1:3))

        ! Check for density after accretion
        if (acc_mass/vol_loc>d .and. (.not. on_creation))then 
           write(*,*),'====================================================='
           write(*,*),'neg density detected :-( at location'
           write(*,*),xx(1:3)
           write(*,*),'due to',isink,acc_mass/vol_loc,d/d_sink,density/d_sink
           write(*,*),indp(j),myid
           write(*,*),nolacc
           do i=1,nsink
              print*,i,' distance ',sum((xx(1:3)-xsink(i,1:3))**2)**0.5/dx_min
           end do
           write(*,*),'====================================================='
           call clean_stop
        end if


        
        if (on_creation)then
           ! accrete
           d=d-acc_mass/vol_loc
           !new gas velocity
           vv(1:3)=(d*vol_loc*vv(1:3)-p_acc(1:3))/(d*vol_loc-acc_mass)                    
           !convert back to conservative variables
           v2=(vv(1)**2+vv(2)**2+vv(3)**2)
#ifdef SOLVERmhd
           e=e+0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
           e=e+0.5d0*v2
           uold(indp(j),1)=d
           uold(indp(j),2)=d*vv(1)
           uold(indp(j),3)=d*vv(2)
           uold(indp(j),4)=d*vv(3)
           uold(indp(j),5)=d*e
           do ivar=imetal,nvar
              uold(indp(j),ivar)=d*z(ivar)
           end do           
        else
           ! modify unew variables
           unew(indp(j),1)=unew(indp(j),1)-acc_mass/vol_loc
           unew(indp(j),2:5)=unew(indp(j),2:5)-uold(indp(j),2:5)*acc_mass/(d*vol_loc)
           do ivar=imetal,nvar
              unew(indp(j),ivar)=unew(indp(j),ivar)-uold(indp(j),ivar)*acc_mass/(d*vol_loc)
           end do
           
           ! put the tangential momentum back into the gas
           if(nolacc)then
              unew(indp(j),2:4)=unew(indp(j),2:4)+acc_mass/(d*vol_loc)*p_rel_tan(1:3)/vol_loc
              unew(indp(j),5)=unew(indp(j),5)+acc_mass/(d*vol_loc)*sum(p_rel_tan(1:3)*uold(indp(j),2:4)/d)
           end if
        end if

     endif
  end do
  
#endif
end subroutine accrete_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine compute_accretion_rate(write_sinks)
  use pm_commons
  use amr_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  logical::write_sinks

  !------------------------------------------------------------------------
  ! This routine computes the accretion rate onto the sink particles based
  ! on the information collected in collect accretion 
  ! It also creates output for the sink particle positions
  !------------------------------------------------------------------------

  integer::i,nx_loc,isink
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v,scale_m
  real(dp)::factG,d_star,boost,vel_max,fa_fact,lambda
  real(dp)::r2,v2,c2,density,volume,ethermal,dx_min,scale,mgas,rho_inf,divergence
  real(dp),dimension(1:3)::velocity
  real(dp),dimension(1:nsinkmax)::dMEDoverdt,dMBHoverdt

  dt_acc=huge(0._dp)

  ! Gravitational constant
  factG=1d0
  if(cosmo)factG=3d0/8d0/3.1415926*omega_m*aexp

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  scale_m=scale_d*scale_l**3d0
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp
  d_star=n_star/scale_nH

  ! Maximum relative velocity
  vel_max=10. ! in km/sec
  vel_max=vel_max*1d5/scale_v
  
  ! Compute sink particle accretion rate by averaging contributions from all levels
!  if(use_acc_rate)then
  do isink=1,nsink
     density=0.d0; volume=0.d0; velocity=0.d0; ethermal=0d0
     divergence=0.d0
     do i=levelmin,nlevelmax
        density=density+weighted_density(isink,i)
        ethermal=ethermal+weighted_ethermal(isink,i)
        velocity(1:3)=velocity(1:3)+weighted_momentum(isink,i,1:3)
        volume=volume+weighted_volume(isink,i)
        divergence=divergence+divsink(isink,i)
     end do
     mgas=density
     density=density/(volume+tiny(0.0_dp))
     if (density>0)then
        velocity(1:3)=velocity(1:3)/(density*volume+tiny(0.0_dp))
        ethermal=ethermal/(density*volume+tiny(0.0_dp))
        c2=MAX((gamma-1.0)*ethermal,smallc**2)
        v2=min(SUM((velocity(1:3)-vsink(isink,1:3))**2),vel_max**2)

        !Bondi radius
        if (smbh)then
           r2=(factG*msink(isink)/(c2+v2))**2
           ! Correct the Bondi radius to limit the accretion to the free fall rate        
           !r2=min(r2,(4.d0*dx_min)**2)  unnecessary when using bondi alpha
        else 
           ! for star formation case add gas mass to the sink mass for young sink particles
           r2=(factG*(msink(isink)+mgas)/(c2+v2))**2
        end if

        ! extrapolate to rho_inf
        rho_inf=density/(bondi_alpha(ir_cloud*0.5*dx_min/r2**0.5))
        ! Krumholz:
        ! rho_inf=density/(bondi_alpha(1.2*dx_min/r2**0.5))


        ! Compute Bondi-Hoyle accretion rate in code units
        boost=1.0
        if(star)boost=max((density/d_star)**2,1.0_dp)

        !use other values for lambda depending on the EOS, this is for isothermal
        lambda=1.12
        dMBHoverdt(isink)=4*3.1415926*rho_inf*r2*sqrt(lambda**2 * c2+v2)


        if (smbh)then 
           !limit accretion by Eddington rate
           dMEDoverdt(isink)=4.*3.1415926*6.67d-8*msink(isink)*1.66d-24/(0.1*6.652d-25*3d10)*scale_t
           dMsink_overdt(isink)=min(dMBHoverdt(isink),dMEDoverdt(isink))
        end if


        bondi_switch(isink)=.false.
        !accretion rate is based on mass flux onto the sink
        if (flux_accretion)then
           !average divergence over all cloud particles and multiply by cloud volume
           dMsink_overdt(isink)=-1.*divergence/ncloud_sink*4./3.*3.14*(ir_cloud*dx_min)**3

           !correct for some small factor to keep density close to threshold
           fa_fact=(log10(density)-log10(d_sink))*0.1+1.
           dMsink_overdt(isink)=dMsink_overdt(isink)*fa_fact

           ! If accretion is subsonic (sonic radius smaller than accretion radius), use Bondi-rate instead.
           if ((0.5*msink(isink)/c2) < (ir_cloud*0.5*dx_min))then
              dMsink_overdt(isink)=dMBHoverdt(isink)
              bondi_switch(isink)=.true.
           end if
        end if

        !make sure, accretion rate is positive
        dMsink_overdt(isink)=max(0.d0,dMsink_overdt(isink))

        !compute maximum timestep allowed by sink
        if (.not. threshold_accretion)dt_acc(isink)=c_acc*mgas/(dMsink_overdt(isink)+tiny(0.d0))
     end if
  end do
 

  if (write_sinks)call print_sink_properties(dMBHoverdt,dMEDoverdt)
  
  !acc_rate=0. !taken away because accretion rate must not be set to 0 before dump_all! now in amr_step just after dump_all
  


contains
  ! Routine to return alpha, defined as rho/rho_inf, for a critical
  ! Bondi accretion solution. The argument is x = r / r_Bondi.
  ! This is from Krumholz et al. (AJC)
  REAL(dp) function bondi_alpha(x)
    implicit none
    REAL(dp) x
    REAL(dp), PARAMETER :: XMIN=0.01, xMAX=2.0
    INTEGER, PARAMETER :: NTABLE=51
    REAL(dp) lambda_c, xtable, xtablep1, alpha_exp
    integer idx
    !     Table of alpha values. These correspond to x values that run from
    !     0.01 to 2.0 with uniform logarithmic spacing. The reason for
    !     this choice of range is that the asymptotic expressions are 
    !     accurate to better than 2% outside this range.
    REAL(dp), PARAMETER, DIMENSION(NTABLE) :: alphatable = (/ &
         820.254, 701.882, 600.752, 514.341, 440.497, 377.381, 323.427, &
         277.295, 237.845, 204.1, 175.23, 150.524, 129.377, 111.27, 95.7613, &
         82.4745, 71.0869, 61.3237, 52.9498, 45.7644, 39.5963, 34.2989, &
         29.7471, 25.8338, 22.4676, 19.5705, 17.0755, 14.9254, 13.0714, &
         11.4717, 10.0903, 8.89675, 7.86467, 6.97159, 6.19825, 5.52812, &
         4.94699, 4.44279, 4.00497, 3.6246, 3.29395, 3.00637, 2.75612, &
         2.53827, 2.34854, 2.18322, 2.03912, 1.91344, 1.80378, 1.70804, &
         1.62439 /)
    !     Define a constant that appears in these formulae
    lambda_c    = 0.25 * exp(1.5)
    !     Deal with the off-the-table cases
    if (x .le. XMIN) then
       bondi_alpha = lambda_c / sqrt(2. * x**3)
    else if (x .ge. XMAX) then
       bondi_alpha = exp(1./x)
    else
       !     We are on the table
       idx = floor ((NTABLE-1) * log(x/XMIN) / log(XMAX/XMIN))
       xtable = exp(log(XMIN) + idx*log(XMAX/XMIN)/(NTABLE-1))
       xtablep1 = exp(log(XMIN) + (idx+1)*log(XMAX/XMIN)/(NTABLE-1))
       alpha_exp = log(x/xtable) / log(xtablep1/xtable)
       !     Note the extra +1s below because of fortran 1 offset arrays
       bondi_alpha = alphatable(idx+1) * (alphatable(idx+2)/alphatable(idx+1))**alpha_exp
    end if
  end function bondi_alpha


end subroutine compute_accretion_rate
!################################################################
!################################################################
!################################################################
!################################################################
subroutine print_sink_properties(dMBHoverdt,dMEDoverdt)
  use pm_commons
  use amr_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  real(dp),dimension(1:nsinkmax)::dMEDoverdt,dMBHoverdt  
  integer::i,isink
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v,scale_m
  real(dp)::l_abs

  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  scale_m=scale_d*scale_l**3d0
  
  if (smbh) then
     if(myid==1.and.nsink>0)then
        xmsink(1:nsink)=msink(1:nsink)
        call quick_sort_dp(xmsink(1),idsink_sort(1),nsink)
        write(*,*)'Number of sink = ',nsink
        write(*,'(" ============================================================================================")')
        write(*,'(" Id     Mass(Msol) Bondi(Msol/yr)   Edd(Msol/yr)              x              y              z")')
        write(*,'(" ============================================================================================")')
        do i=nsink,max(nsink-10,1),-1
           isink=idsink_sort(i)
           write(*,'(I3,10(1X,1PE14.7))')idsink(isink),msink(isink)*scale_m/2d33 &
                & ,dMBHoverdt(isink)*scale_m/scale_t/(2d33/(365.*24.*3600.)) &
                & ,dMEDoverdt(isink)*scale_m/scale_t/(2d33/(365.*24.*3600.)) &
                & ,xsink(isink,1:ndim),delta_mass(isink)*scale_m/2d33
        end do
        write(*,'(" ============================================================================================")')
     endif
  end if
  if (.not. smbh)then    
     if(myid==1.and.nsink>0.and. mod(nstep_coarse,ncontrol)==0)then
        xmsink(1:nsink)=msink(1:nsink)
        call quick_sort_dp(xmsink(1),idsink_sort(1),nsink)
        write(*,*)'Number of sink = ',nsink
        write(*,*)'Total mass in sink = ',sum(msink(1:nsink))*scale_m/1.9891d33
        write(*,*)'simulation time = ',t
        write(*,'(" ======================================================================================================================== ")')
        write(*,'("  Id     M[Msol]    x           y           z           vx       vy       vz     acc_rate[Msol/y] acc_lum[Lsol]    age   ")')
        write(*,'(" ======================================================================================================================== ")')
        do i=nsink,1,-1
           isink=idsink_sort(i)
           l_abs=(lsink(isink,1)**2+lsink(isink,2)**2+lsink(isink,3)**2)**0.5+1.d10*tiny(0.d0)
           write(*,'(I5,2X,F9.5,3(2X,F10.7),3(2X,F7.4),2X,3(2X,E11.3))')&
                idsink(isink),msink(isink)*scale_m/1.9891d33, &
                xsink(isink,1:ndim),vsink(isink,1:ndim),&
                acc_rate(isink)*scale_m/1.9891d33/(scale_t)*365.*24.*3600.,acc_lum(isink)/scale_t**2*scale_l**3*scale_d*scale_l**2/scale_t/3.9d33,&
                (t-tsink(isink))*scale_t/(3600*24*365.25)
        end do
        write(*,'(" ======================================================================================================================== ")')
     endif
  endif
end subroutine print_sink_properties
!################################################################
!################################################################
!################################################################
!################################################################
subroutine agn_feedback
  use amr_commons
  use pm_commons
  use hydro_commons
!  use cooling_module, ONLY: XH=>X, rhoc, mH 
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------
  ! Description: This subroutine checks SN events in cells where a
  ! star particle has been spawned.
  ! Yohan Dubois
  !----------------------------------------------------------------------

  ! local constants
  integer::info,isink,ilevel,ivar
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(dp)::scale,dx_min,vol_min,temp_blast
  real(dp)::T2_AGN,T2_min,T2_max,delta_mass_max
  integer::nx_loc


  if(.not. hydro)return
  if(ndim.ne.3)return

  if(verbose)write(*,*)'Entering make_sn'
  
  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  ! Mesh spacing in that level
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=(0.5D0**nlevelmax)*scale
  vol_min=dx_min**ndim

  ! AGN specific energy
  T2_AGN=0.15*1d12 ! in Kelvin

  ! Minimum specific energy
  T2_min=1d7  ! in Kelvin

  ! Maximum specific energy
  T2_max=1d9 ! in Kelvin

  ! Compute the grid discretization effects
  call average_AGN

  ! Check if sink goes into blast wave mode
  ok_blast_agn(1:nsink)=.false.
  do isink=1,nsink
     ! Compute estimated average temperature in the blast
     temp_blast=0.0
     if(vol_gas_agn(isink)>0.0)then
        temp_blast=T2_AGN*delta_mass(isink)/mass_gas_agn(isink)
     else
        if(ind_blast_agn(isink)>0)then
           temp_blast=T2_AGN*delta_mass(isink)/mass_blast_agn(isink)
        endif
     endif
     if(temp_blast>T2_min)then
        ok_blast_agn(isink)=.true.
     endif
  end do
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ok_blast_agn,ok_blast_agn_all,nsink,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,info)
  ok_blast_agn=ok_blast_agn_all
#endif

  ! Modify hydro quantities to account for the AGN blast
  call AGN_blast

  ! Reset accreted mass
  do isink=1,nsink
     if(ok_blast_agn(isink))then
        if(myid==1)then
           write(*,'("***BLAST***",I4,1X,2(1PE12.5,1X))')isink &
                & ,msink(isink)*scale_d*scale_l**3/2d33 &  
                & ,delta_mass(isink)*scale_d*scale_l**3/2d33
        endif
        ! Compute estimated average temperature in the blast
        temp_blast=0.0
        if(vol_gas_agn(isink)>0.0)then
           temp_blast=T2_AGN*delta_mass(isink)/mass_gas_agn(isink)
        else
           if(ind_blast_agn(isink)>0)then
              temp_blast=T2_AGN*delta_mass(isink)/mass_blast_agn(isink)
           endif
        endif
        if(temp_blast<T2_max)then
           delta_mass(isink)=0.0
        else
           if(vol_gas_agn(isink)>0.0)then
              delta_mass_max=T2_max/T2_AGN*mass_gas_agn(isink)
           else
              if(ind_blast_agn(isink)>0)then
                 delta_mass_max=T2_max/T2_AGN*mass_blast_agn(isink)
              endif
           endif
           delta_mass(isink)=max(delta_mass(isink)-delta_mass_max,0.0_dp)
        endif
     endif
  end do

  ! Update hydro quantities for split cells
  do ilevel=nlevelmax,levelmin,-1
     call upload_fine(ilevel)
     do ivar=1,nvar
        call make_virtual_fine_dp(uold(1,ivar),ilevel)
     enddo
  enddo

end subroutine agn_feedback
!################################################################
!################################################################
!################################################################
!################################################################
subroutine average_AGN
  use pm_commons
  use amr_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !------------------------------------------------------------------------
  ! This routine average the hydro quantities inside the SN bubble
  !------------------------------------------------------------------------

  integer::ilevel,ncache,isink,ind,ix,iy,iz,ngrid,iskip
  integer::i,nx_loc,igrid,info
  integer,dimension(1:nvector)::ind_grid,ind_cell
  real(dp)::x,y,z,drr,dr_cell
  real(dp)::scale,dx,dxx,dyy,dzz,dx_min,dx_loc,vol_loc,rmax2,rmax
  real(dp),dimension(1:3)::skip_loc
  real(dp),dimension(1:twotondim,1:3)::xc
  logical ,dimension(1:nvector)::ok

  if(nsink==0)return
  if(verbose)write(*,*)'Entering average_AGN'

  ! Mesh spacing in that level
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  skip_loc(1)=dble(icoarse_min)
  skip_loc(2)=dble(jcoarse_min)
  skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax

  ! Maximum radius of the ejecta
  rmax=ind_rsink*dx_min/aexp
  rmax2=rmax*rmax

  ! Initialize the averaged variables
  vol_gas_agn=0.0;vol_blast_agn=0.0;mass_gas_agn=0.0;ind_blast_agn=-1

  ! Loop over levels
  do ilevel=levelmin,nlevelmax
     ! Computing local volume (important for averaging hydro quantities) 
     dx=0.5D0**ilevel 
     dx_loc=dx*scale
     vol_loc=dx_loc**ndim
     ! Cells center position relative to grid center position
     do ind=1,twotondim  
        iz=(ind-1)/4
        iy=(ind-1-4*iz)/2
        ix=(ind-1-2*iy-4*iz)
        xc(ind,1)=(dble(ix)-0.5D0)*dx
        xc(ind,2)=(dble(iy)-0.5D0)*dx
        xc(ind,3)=(dble(iz)-0.5D0)*dx
     end do

     ! Loop over grids
     ncache=active(ilevel)%ngrid
     do igrid=1,ncache,nvector
        ngrid=MIN(nvector,ncache-igrid+1)
        do i=1,ngrid
           ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
        end do

        ! Loop over cells
        do ind=1,twotondim  
           iskip=ncoarse+(ind-1)*ngridmax
           do i=1,ngrid
              ind_cell(i)=iskip+ind_grid(i)
           end do

           ! Flag leaf cells
           do i=1,ngrid
              ok(i)=son(ind_cell(i))==0
           end do

           do i=1,ngrid
              if(ok(i))then
                 ! Get gas cell position
                 x=(xg(ind_grid(i),1)+xc(ind,1)-skip_loc(1))*scale
                 y=(xg(ind_grid(i),2)+xc(ind,2)-skip_loc(2))*scale
                 z=(xg(ind_grid(i),3)+xc(ind,3)-skip_loc(3))*scale

                 do isink=1,nsink
                    ! Check if the cell lies within the sink radius
                    dxx=x-xsink(isink,1)
                    if(dxx> 0.5*scale)then
                       dxx=dxx-scale
                    endif
                    if(dxx<-0.5*scale)then
                       dxx=dxx+scale
                    endif
                    dyy=y-xsink(isink,2)
                    if(dyy> 0.5*scale)then
                       dyy=dyy-scale
                    endif
                    if(dyy<-0.5*scale)then
                       dyy=dyy+scale
                    endif
                    dzz=z-xsink(isink,3)
                    if(dzz> 0.5*scale)then
                       dzz=dzz-scale
                    endif
                    if(dzz<-0.5*scale)then
                       dzz=dzz+scale
                    endif
                    drr=dxx*dxx+dyy*dyy+dzz*dzz
                    dr_cell=MAX(ABS(dxx),ABS(dyy),ABS(dzz))
                    if(drr.lt.rmax2)then
                       vol_gas_agn(isink)=vol_gas_agn(isink)+vol_loc
                       mass_gas_agn(isink)=mass_gas_agn(isink)+vol_loc*uold(ind_cell(i),1)
                    endif
                    if(dr_cell.le.dx_loc/2.0)then
                       ind_blast_agn(isink)=ind_cell(i)
                       vol_blast_agn(isink)=vol_loc
                       mass_blast_agn(isink)=vol_loc*uold(ind_cell(i),1)
                    endif
                 end do
              endif
           end do           
        end do
        ! End loop over cells
     end do
     ! End loop over grids
  end do
  ! End loop over levels

#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(vol_gas_agn,vol_gas_agn_all,nsink,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(mass_gas_agn,mass_gas_agn_all,nsink,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  vol_gas_agn=vol_gas_agn_all
  mass_gas_agn=mass_gas_agn_all
#endif

  if(verbose)write(*,*)'Exiting average_AGN'

end subroutine average_AGN
!################################################################
!################################################################
!################################################################
!################################################################
subroutine AGN_blast
  use pm_commons
  use amr_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !------------------------------------------------------------------------
  ! This routine merges SN using the FOF algorithm.
  !------------------------------------------------------------------------

  integer::ilevel,isink,ind,ix,iy,iz,ngrid,iskip
  integer::i,nx_loc,igrid,ncache
  integer,dimension(1:nvector)::ind_grid,ind_cell
  real(dp)::x,y,z,dx,dxx,dyy,dzz,drr
  real(dp)::scale,dx_min,dx_loc,vol_loc,rmax2,rmax,T2_AGN,T2_max
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(dp),dimension(1:3)::skip_loc
  real(dp),dimension(1:twotondim,1:3)::xc
  logical ,dimension(1:nvector)::ok


  if(nsink==0)return
  if(verbose)write(*,*)'Entering AGN_blast'

  ! Mesh spacing in that level
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  skip_loc(1)=dble(icoarse_min)
  skip_loc(2)=dble(jcoarse_min)
  skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  ! Maximum radius of the ejecta
  rmax=ind_rsink*dx_min/aexp
  rmax2=rmax*rmax
  
  ! AGN specific energy
  T2_AGN=0.15*1d12 ! in Kelvin
  T2_AGN=T2_AGN/scale_T2 ! in code units

  ! Maximum specific energy
  T2_max=1d9 ! in Kelvin
  T2_max=T2_max/scale_T2 ! in code units

  ! Loop over levels
  do ilevel=levelmin,nlevelmax
     ! Computing local volume (important for averaging hydro quantities) 
     dx=0.5D0**ilevel 
     dx_loc=dx*scale
     vol_loc=dx_loc**ndim
     ! Cells center position relative to grid center position
     do ind=1,twotondim  
        iz=(ind-1)/4
        iy=(ind-1-4*iz)/2
        ix=(ind-1-2*iy-4*iz)
        xc(ind,1)=(dble(ix)-0.5D0)*dx
        xc(ind,2)=(dble(iy)-0.5D0)*dx
        xc(ind,3)=(dble(iz)-0.5D0)*dx
     end do

     ! Loop over grids
     ncache=active(ilevel)%ngrid
     do igrid=1,ncache,nvector
        ngrid=MIN(nvector,ncache-igrid+1)
        do i=1,ngrid
           ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
        end do

        ! Loop over cells
        do ind=1,twotondim  
           iskip=ncoarse+(ind-1)*ngridmax
           do i=1,ngrid
              ind_cell(i)=iskip+ind_grid(i)
           end do

           ! Flag leaf cells
           do i=1,ngrid
              ok(i)=son(ind_cell(i))==0
           end do

           do i=1,ngrid
              if(ok(i))then
                 ! Get gas cell position
                 x=(xg(ind_grid(i),1)+xc(ind,1)-skip_loc(1))*scale
                 y=(xg(ind_grid(i),2)+xc(ind,2)-skip_loc(2))*scale
                 z=(xg(ind_grid(i),3)+xc(ind,3)-skip_loc(3))*scale
                 do isink=1,nsink
                    ! Check if sink is in blast mode
                    if(ok_blast_agn(isink))then
                       ! Check if the cell lies within the sink radius
                       dxx=x-xsink(isink,1)
                       if(dxx> 0.5*scale)then
                          dxx=dxx-scale
                       endif
                       if(dxx<-0.5*scale)then
                          dxx=dxx+scale
                       endif
                       dyy=y-xsink(isink,2)
                       if(dyy> 0.5*scale)then
                          dyy=dyy-scale
                       endif
                       if(dyy<-0.5*scale)then
                          dyy=dyy+scale
                       endif
                       dzz=z-xsink(isink,3)
                       if(dzz> 0.5*scale)then
                          dzz=dzz-scale
                       endif
                       if(dzz<-0.5*scale)then
                          dzz=dzz+scale
                       endif
                       drr=dxx*dxx+dyy*dyy+dzz*dzz
                       
                       if(drr.lt.rmax2)then
                          ! Update the total energy of the gas
                          p_agn(isink)=MIN(delta_mass(isink)*T2_AGN*uold(ind_cell(i),1)/mass_gas_agn(isink), &
                               &         T2_max*uold(ind_cell(i),1)  )
                          uold(ind_cell(i),5)=uold(ind_cell(i),5)+p_agn(isink)
                       endif
                    endif
                 end do
              endif
           end do
           
        end do
        ! End loop over cells
     end do
     ! End loop over grids
  end do
  ! End loop over levels

  do isink=1,nsink
     if(ok_blast_agn(isink).and.vol_gas_agn(isink)==0d0)then
        if(ind_blast_agn(isink)>0)then
           p_agn(isink)=MIN(delta_mass(isink)*T2_AGN*uold(ind_blast_agn(isink),1)/mass_blast_agn(isink), &
                &       T2_max*uold(ind_cell(i),1)  )
            uold(ind_blast_agn(isink),5)=uold(ind_blast_agn(isink),5)+p_agn(isink)
        endif
     endif
  end do

  if(verbose)write(*,*)'Exiting AGN_blast'

end subroutine AGN_blast
!###########################################################
!###########################################################
!###########################################################
!###########################################################
subroutine quenching(ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::ilevel

  !------------------------------------------------------------------------
  ! This routine selects regions which are eligible for SMBH formation.
  ! It is based on a stellar density threshold and on a stellar velocity
  ! dispersion threshold.
  ! On exit, flag2 array is set to 0 for AGN sites and to 1 otherwise.
  !------------------------------------------------------------------------

  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(dp)::dx,dx_loc,scale,vol_loc
  real(dp)::str_d,tot_m,ave_u,ave_v,ave_w,sig_u,sig_v,sig_w
  integer::igrid,ipart,jpart,next_part,ind_cell,iskip,ind
  integer::i,npart1,npart2,nx_loc
  real(dp),dimension(1:3)::skip_loc

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  ! Mesh spacing in that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim

#if NDIM==3
  ! Gather star particles only.

  ! Loop over grids
  do i=1,active(ilevel)%ngrid
     igrid=active(ilevel)%igrid(i)
     ! Number of particles in the grid
     npart1=numbp(igrid)
     npart2=0
     
     ! Reset velocity moments
     str_d=0.0
     tot_m=0.0
     ave_u=0.0
     ave_v=0.0
     ave_w=0.0
     sig_u=0.0
     sig_v=0.0
     sig_w=0.0
     
     ! Count star particles
     if(npart1>0)then
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle   <--- Very important !!!
           next_part=nextp(ipart)
           if(idp(ipart).gt.0.and.tp(ipart).ne.0)then
              npart2=npart2+1
              tot_m=tot_m+mp(ipart)
              ave_u=ave_u+mp(ipart)*vp(ipart,1)
              ave_v=ave_v+mp(ipart)*vp(ipart,2)
              ave_w=ave_w+mp(ipart)*vp(ipart,3)
              sig_u=sig_u+mp(ipart)*vp(ipart,1)**2
              sig_v=sig_v+mp(ipart)*vp(ipart,2)**2
              sig_w=sig_w+mp(ipart)*vp(ipart,3)**2
           endif
           ipart=next_part  ! Go to next particle
        end do
     endif
     
     ! Normalize velocity moments
     if(npart2.gt.0)then
        ave_u=ave_u/tot_m
        ave_v=ave_v/tot_m
        ave_w=ave_w/tot_m
        sig_u=sqrt(sig_u/tot_m-ave_u**2)*scale_v/1d5
        sig_v=sqrt(sig_v/tot_m-ave_v**2)*scale_v/1d5
        sig_w=sqrt(sig_w/tot_m-ave_w**2)*scale_v/1d5
        str_d=tot_m/(2**ndim*vol_loc)*scale_nH
     endif
     
     ! Loop over cells
     do ind=1,twotondim
        iskip=ncoarse+(ind-1)*ngridmax
        ind_cell=iskip+igrid
        ! AGN formation sites
        ! if n_star>0.1 H/cc and v_disp>100 km/s
        if(str_d>0.1.and.MAX(sig_u,sig_v,sig_w)>100.)then
           flag2(ind_cell)=0
        else
           flag2(ind_cell)=1
        end if
     end do
  end do
  ! End loop over grids

#endif

111 format('   Entering quenching for level ',I2)

end subroutine quenching
!################################################################
!################################################################
!################################################################
!################################################################
!################################################################
!################################################################
subroutine make_sink_from_clump(ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  use poisson_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel

  !----------------------------------------------------------------------
  ! This routine uses creates a sink in every cell which was flagged (flag2)
  ! The global sink variables are updated
  ! The true RAMSES particle is NOT produced here...
  !----------------------------------------------------------------------

  integer ::ncache,nnew,ivar,ngrid,icpu,index_sink,index_sink_tot
  integer ::igrid,ix,iy,iz,ind,i,iskip,isink,nx_loc
  integer ::ntot,ntot_all,info
  integer ,dimension(1:nvector)::ind_grid,ind_cell
  integer ,dimension(1:nvector)::ind_grid_new,ind_cell_new
  integer ,dimension(1:ncpu)::ntot_sink_cpu,ntot_sink_all
  logical ::ok_free
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v,scale_m
  real(dp)::d,u,v,w,e,factG,delta_d,v2,fourpi,threepi2,tff,tsal
  real(dp)::rmax,rmax2
  real(dp)::d_thres,birth_epoch
  real(dp)::dx,dx_loc,scale,vol_loc,dx_min,vol_min
  real(dp),dimension(1:nvar)::z
  real(dp),dimension(1:3)::skip_loc,x
  real(dp),dimension(1:twotondim,1:3)::xc
#ifdef SOLVERmhd
  real(dp)::bx1,bx2,by1,by2,bz1,bz2
#endif
  
  if(.not. hydro)return
  if(ndim.ne.3)return

  if(verbose)write(*,*)'entering make_sink_from_clump for level ',ilevel

  ! Conversion factor from user units to cgs units                              
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  scale_m=scale_d*scale_l**3

  ! Gravitational constant
  factG=1d0
  if(cosmo)factG=3d0/8d0/3.1415926*omega_m*aexp

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim
  dx_min=(0.5D0**nlevelmax)*scale
  vol_min=dx_min**ndim

  rmax=dble(ir_cloud)*dx_min/aexp ! Linking length in physical units
  rmax2=rmax*rmax

  ! Birth epoch as proper time
  if(use_proper_time)then
     birth_epoch=texp
  else
     birth_epoch=t
  endif

  ! Cells center position relative to grid center position
  do ind=1,twotondim  
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     xc(ind,1)=(dble(ix)-0.5D0)*dx
     xc(ind,2)=(dble(iy)-0.5D0)*dx
     xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do

  ! Set new sink variables to zero
  msink_new=0d0; tsink_new=0d0; delta_mass_new=0d0; xsink_new=0d0; vsink_new=0d0
  oksink_new=0d0; idsink_new=0; new_born_new=.false.

#if NDIM==3

  !------------------------------------------------
  ! and count number of new sinks (flagged cells)
  !------------------------------------------------
  ntot=0
  ntot_sink_cpu=0
  if(numbtot(1,ilevel)>0)then
     ncache=active(ilevel)%ngrid
     do igrid=1,ncache,nvector
        ngrid=MIN(nvector,ncache-igrid+1)
        do i=1,ngrid
           ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
        end do
        do ind=1,twotondim  
           iskip=ncoarse+(ind-1)*ngridmax
           do i=1,ngrid
              ind_cell(i)=iskip+ind_grid(i)
           end do
           do i=1,ngrid
              if(flag2(ind_cell(i))>0)then
                 ntot=ntot+1
              end if
           end do
        end do
     end do
  end if

  !---------------------------------
  ! Compute global sink statistics
  !---------------------------------
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ntot,ntot_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  ntot_all=ntot
#endif
#ifndef WITHOUTMPI
  ntot_sink_cpu=0; ntot_sink_all=0
  ntot_sink_cpu(myid)=ntot
  call MPI_ALLREDUCE(ntot_sink_cpu,ntot_sink_all,ncpu,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
  ntot_sink_cpu(1)=ntot_sink_all(1)
  do icpu=2,ncpu
     ntot_sink_cpu(icpu)=ntot_sink_cpu(icpu-1)+ntot_sink_all(icpu)
  end do
#endif
  nsink=nsink+ntot_all  
  nindsink=nindsink+ntot_all
  if(myid==1)then
     if(ntot_all.gt.0)then
        write(*,'(" Level = ",I6," New sinks produced from clumps= ",I6," Total sinks =",I8)')&
             & ilevel,ntot_all,nsink
     endif
  end if

  !-------------------------------------------
  ! Check wether max number of sink is reached
  !------------------------------------------
  ok_free=(nsink+ntot_all<=nsinkmax)
  if(.not. ok_free .and. myid==1)then
     write(*,*)'global list of sink particles is too long'
     write(*,*)'New sink particles',ntot_all
     write(*,*)'Increase nsinkmax'
#ifndef WITHOUTMPI
     call MPI_ABORT(MPI_COMM_WORLD,1,info)
#endif
#ifdef WITHOUTMPI
     stop
#endif
  end if
   
  !------------------------------
  ! Create new sink particles
  !------------------------------
  ! Starting identity number
  if(myid==1)then
     index_sink=nsink-ntot_all
     index_sink_tot=nindsink-ntot_all
  else
     index_sink=nsink-ntot_all+ntot_sink_cpu(myid-1)
     index_sink_tot=nindsink-ntot_all+ntot_sink_cpu(myid-1)
  end if
  
  ! Loop over grids
  if(numbtot(1,ilevel)>0)then
     ncache=active(ilevel)%ngrid
     do igrid=1,ncache,nvector
        ngrid=MIN(nvector,ncache-igrid+1)
        do i=1,ngrid
           ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
        end do

        ! Loop over cells
        do ind=1,twotondim
           iskip=ncoarse+(ind-1)*ngridmax
           do i=1,ngrid
              ind_cell(i)=iskip+ind_grid(i)
           end do

           ! Gather cells with a new sink
           nnew=0
           do i=1,ngrid
              if (flag2(ind_cell(i))>0)then
                 nnew=nnew+1
                 ind_grid_new(nnew)=ind_grid(i)
                 ind_cell_new(nnew)=ind_cell(i)
              end if
           end do

           ! Create new sink particles
           do i=1,nnew
              index_sink=index_sink+1
              index_sink_tot=index_sink_tot+1

              ! Convert uold to primitive variables
              d=uold(ind_cell_new(i),1)
              u=uold(ind_cell_new(i),2)/d
              v=uold(ind_cell_new(i),3)/d
              w=uold(ind_cell_new(i),4)/d
              e=uold(ind_cell_new(i),5)/d
#ifdef SOLVERmhd
              bx1=uold(ind_cell_new(i),6)
              by1=uold(ind_cell_new(i),7)
              bz1=uold(ind_cell_new(i),8)
              bx2=uold(ind_cell_new(i),nvar+1)
              by2=uold(ind_cell_new(i),nvar+2)
              bz2=uold(ind_cell_new(i),nvar+3)
              e=e-0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
              v2=(u**2+v**2+w**2)
              e=e-0.5d0*v2
              do ivar=imetal,nvar
                 z(ivar)=uold(ind_cell_new(i),ivar)/d
              end do
              
              ! Get density maximum by quadratic expansion around cell center
              x(1)=(xg(ind_grid_new(i),1)+xc(ind,1)-skip_loc(1))*scale
              x(2)=(xg(ind_grid_new(i),2)+xc(ind,2)-skip_loc(2))*scale
              x(3)=(xg(ind_grid_new(i),3)+xc(ind,3)-skip_loc(3))*scale              
              call true_max(x(1),x(2),x(3),nlevelmax)

              ! User defined density threshold
              d_thres=d_sink

              ! Mass of the new sink
              ! if(smbh)then
              !    ! The SMBH/sink mass is the mass that will heat the gas to 10**7 K after creation
              !    fourpi=4.0d0*ACOS(-1.0d0)
              !    threepi2=3.0d0*ACOS(-1.0d0)**2
              !    if(cosmo)fourpi=1.5d0*omega_m*aexp
              !    tff=sqrt(threepi2/8./fourpi/(d+1d-30))
              !    tsal=0.1*6.652d-25*3d10/4./3.1415926/6.67d-8/1.66d-24/scale_t
              !    msink_new(index_sink)=1.d-5/0.15*clump_mass_tot4(flag2(ind_cell_new(i)))*tsal/tff
              !    delta_d=d-msink_new(index_sink)/vol_loc
              !    if(delta_d<0.)write(*,*)'sink production with negative mass'
              ! else
                 delta_d=d*0.000001!00001
                 if (d>0.)then
                    msink_new(index_sink)=delta_d*vol_loc
                 else
                    write(*,*)'sink production with negative mass'
                    call clean_stop
                 endif
!              end if

              delta_mass_new(index_sink)=msink_new(index_sink)

              ! Global index of the new sink
              oksink_new(index_sink)=1d0
              idsink_new(index_sink)=index_sink_tot

              ! Store properties of the new sink
              tsink_new(index_sink)=birth_epoch
              xsink_new(index_sink,1:3)=x(1:3)
              vsink_new(index_sink,1)=u
              vsink_new(index_sink,2)=v
              vsink_new(index_sink,3)=w
              new_born_new(index_sink)=.true.

              ! Convert back to conservative variable                                             
              d=d-delta_d
#ifdef SOLVERmhd
              e=e+0.125d0*((bx1+bx2)**2+(by1+by2)**2+(bz1+bz2)**2)/d
#endif
              e=e+0.5d0*(u**2+v**2+w**2)
              uold(ind_cell_new(i),1)=d
              uold(ind_cell_new(i),2)=d*u
              uold(ind_cell_new(i),3)=d*v
              uold(ind_cell_new(i),4)=d*w
              uold(ind_cell_new(i),5)=d*e
              do ivar=imetal,nvar
                 uold(ind_cell_new(i),ivar)=d*z(ivar)
              end do
           end do
           ! End loop over new sink particle cells
        end do
        ! End loop over cells
     end do
     ! End loop over grids
  end if

#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(oksink_new,oksink_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(idsink_new,idsink_all,nsinkmax,MPI_INTEGER         ,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(msink_new ,msink_all ,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(tsink_new ,tsink_all ,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(xsink_new ,xsink_all ,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(vsink_new ,vsink_all ,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(delta_mass_new,delta_mass_all,nsinkmax,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
  call MPI_ALLREDUCE(new_born_new,new_born_all,nsinkmax,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,info)
#else
  oksink_all=oksink_new
  idsink_all=idsink_new
  msink_all=msink_new
  tsink_all=tsink_new
  xsink_all=xsink_new
  vsink_all=vsink_new
  delta_mass_all=delta_mass_new
  new_born_all=new_born_new
#endif
  do isink=1,nsink
     if(oksink_all(isink)==1)then
        idsink(isink)=idsink_all(isink)
        msink(isink)=msink_all(isink)
        tsink(isink)=tsink_all(isink)
        xsink(isink,1:ndim)=xsink_all(isink,1:ndim)
        vsink(isink,1:ndim)=vsink_all(isink,1:ndim)
        delta_mass(isink)=delta_mass_all(isink)
        acc_rate(isink)=msink_all(isink)
        new_born(isink)=new_born_all(isink)
     endif
  end do
#endif

end subroutine make_sink_from_clump
!################################################################
!################################################################
!################################################################
!################################################################
subroutine true_max(x,y,z,ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  real(dp)::x,y,z
  integer::ilevel

  !----------------------------------------------------------------------------
  ! Description: This subroutine takes the cell of maximum density and computes
  ! the true maximum by expanding the density around the cell center to second order.
  !----------------------------------------------------------------------------

  integer::k,j,i,nx_loc
  integer,dimension(1:nvector)::cell_index,cell_lev
  real(dp)::det,dx,dx_loc,scale,disp_max
  real(dp),dimension(-1:1,-1:1,-1:1)::cube3
  real(dp),dimension(1:nvector,1:ndim)::xtest
  real(dp),dimension(1:ndim)::gradient,displacement
  real(dp),dimension(1:ndim,1:ndim)::hess,minor
  real(dp),dimension(1:3)::skip_loc

#if NDIM==3

  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale


  do i=-1,1
     do j=-1,1
        do k=-1,1

           xtest(1,1)=x+i*dx_loc
#if NDIM>1
           xtest(1,2)=y+j*dx_loc
#endif
#if NDIM>2
           xtest(1,3)=z+k*dx_loc
#endif
           call get_cell_index(cell_index,cell_lev,xtest,ilevel,1)
           cube3(i,j,k)=uold(cell_index(1),1)

        end do
     end do
  end do

! compute gradient
  gradient(1)=0.5*(cube3(1,0,0)-cube3(-1,0,0))/dx_loc
  gradient(2)=0.5*(cube3(0,1,0)-cube3(0,-1,0))/dx_loc
  gradient(3)=0.5*(cube3(0,0,1)-cube3(0,0,-1))/dx_loc

  if (maxval(abs(gradient(1:3)))==0.)return  

  ! compute hessian
  hess(1,1)=(cube3(1,0,0)+cube3(-1,0,0)-2*cube3(0,0,0))/dx_loc**2.
  hess(2,2)=(cube3(0,1,0)+cube3(0,-1,0)-2*cube3(0,0,0))/dx_loc**2.
  hess(3,3)=(cube3(0,0,1)+cube3(0,0,-1)-2*cube3(0,0,0))/dx_loc**2.
  
  hess(1,2)=0.25*(cube3(1,1,0)+cube3(-1,-1,0)-cube3(1,-1,0)-cube3(-1,1,0))/dx_loc**2.
  hess(2,1)=hess(1,2)
  hess(1,3)=0.25*(cube3(1,0,1)+cube3(-1,0,-1)-cube3(1,0,-1)-cube3(-1,0,1))/dx_loc**2.
  hess(3,1)=hess(1,3)
  hess(2,3)=0.25*(cube3(0,1,1)+cube3(0,-1,-1)-cube3(0,1,-1)-cube3(0,-1,1))/dx_loc**2.
  hess(3,2)=hess(2,3)

  !determinant
  det=hess(1,1)*hess(2,2)*hess(3,3)+hess(1,2)*hess(2,3)*hess(3,1)+hess(1,3)*hess(2,1)*hess(3,2) &
       -hess(1,1)*hess(2,3)*hess(3,2)-hess(1,2)*hess(2,1)*hess(3,3)-hess(1,3)*hess(2,2)*hess(3,1)

  !matrix of minors
  minor(1,1)=hess(2,2)*hess(3,3)-hess(2,3)*hess(3,2)
  minor(2,2)=hess(1,1)*hess(3,3)-hess(1,3)*hess(3,1)
  minor(3,3)=hess(1,1)*hess(2,2)-hess(1,2)*hess(2,1)

  minor(1,2)=-1.*(hess(2,1)*hess(3,3)-hess(2,3)*hess(3,1))
  minor(2,1)=minor(1,2)
  minor(1,3)=hess(2,1)*hess(3,2)-hess(2,2)*hess(3,1)
  minor(3,1)=minor(1,3)
  minor(2,3)=-1.*(hess(1,1)*hess(3,2)-hess(1,2)*hess(3,1))
  minor(3,2)=minor(2,3)


  !displacement of the true max from the cell center
  displacement=0.
  do i=1,3
     do j=1,3
        displacement(i)=displacement(i)-minor(i,j)/(det+1.d10*tiny(0.d0))*gradient(j)
     end do
  end do

  !clipping the displacement in order to keep max in the cell
  disp_max=maxval(abs(displacement(1:3)))
  if (disp_max > dx_loc*0.5)then
     displacement(1)=displacement(1)/disp_max*dx_loc*0.5
     displacement(2)=displacement(2)/disp_max*dx_loc*0.5
     displacement(3)=displacement(3)/disp_max*dx_loc*0.5
  end if

  x=x+displacement(1)
  y=y+displacement(2)
  z=z+displacement(3)

#endif
end subroutine true_max
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine update_sink(ilevel)
  use amr_commons
  use pm_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! This routine is called at the leafs of the tree structure (right after    
! update time). Here is where the global sink variables vsink and xsink are 
! updated by summing the conributions from all levels.                      
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  real(dp)::dteff,vnorm_rel,mach,alpha,d_star,factor,fudge,twopi
  real(dp)::scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2
  integer::lev,isink,i,info
  real(dp),dimension(1:nsinkmax)::densc,volc
  real(dp),dimension(1:nsinkmax,1:ndim)::velc,fdrag
  real(dp),dimension(1:ndim)::vrel

#if NDIM==3

  if(verbose)write(*,*)'Entering update_sink for level ',ilevel



  call f_sink_sink

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  twopi=2d0*acos(-1d0)
  fudge=2d0*twopi*6.67d-8**2*scale_d**2*scale_t**4
  if (star)then
     d_star=n_star/scale_nH
  else
     d_star=5d1/scale_nH
  endif

  densc=0.d0; volc=0.d0; velc=0.d0

  vsold(1:nsink,1:ndim,ilevel)=vsnew(1:nsink,1:ndim,ilevel)
  vsnew(1:nsink,1:ndim,ilevel)=vsink(1:nsink,1:ndim)

  do isink=1,nsink
     ! sum force contributions from all levels and gather 
     if (.not. direct_force_sink(isink))fsink(isink,1:ndim)=0.
     
     if(smbh) then
        do lev=levelmin,nlevelmax
           fsink(isink,1:ndim)=fsink(isink,1:ndim)+fsink_partial(isink,1:ndim,lev)
           densc(isink)=densc(isink)+weighted_density(isink,lev)*weighted_volume(isink,lev)
           velc(isink,1:ndim)=velc(isink,1:ndim)+weighted_momentum(isink,lev,1:ndim)
           volc(isink)=volc(isink)+weighted_volume(isink,lev)
        end do
        fsink(isink,1:ndim)=fsink(isink,1:ndim)/dble(ncloud_sink)
        velc(isink,1:ndim)=velc(isink,1:ndim)/densc(isink)
        densc(isink)=densc(isink)/volc(isink)
     else
        do lev=levelmin,nlevelmax
           fsink(isink,1:ndim)=fsink(isink,1:ndim)+fsink_partial(isink,1:ndim,lev)
        end do
        if (.not. direct_force_sink(isink))then
           fsink(isink,1:ndim)=fsink(isink,1:ndim)/dble(ncloud_sink)
        end if
     end if

     ! BS
     ! if (direct_force_sink(isink))then
     !    if (level_sink(isink)==0)then
     !       dteff=0.d0
     !    else
     !       !direct force sinks are advanced at the finest level timestep
     !       dteff=dtold(level_sink(isink))
     !    end if
     ! end if
     
     ! timestep must be zero for newly produced sink
     if (new_born(isink))then
        dteff=0d0 
     else
        ! compute timestep for the synchronization
        if(sinkint_level>ilevel)then
           dteff=dtnew(sinkint_level)
        else 
           dteff=dtold(sinkint_level)
        end if
     end if
     
     ! this is the kick-kick (half old half new timestep)
     ! old timestep might be the one of a different level
     vsink(isink,1:ndim)=0.5D0*(dtnew(ilevel)+dteff)*fsink(isink,1:ndim)+vsink(isink,1:ndim)

     ! save the velocity
     vsnew(isink,1:ndim,ilevel)=vsink(isink,1:ndim)

     if(smbh)then
        fdrag(isink,1:ndim)=0.d0
        ! Compute the drag force exerted by the gas on the sink particle 
        vrel(1:ndim)=vsnew(isink,1:ndim,ilevel)-velc(isink,1:ndim)
        vnorm_rel=sqrt( vrel(1)**2 + vrel(2)**2 + vrel(3)**2 )
        mach=vnorm_rel/sqrt(c2sink_all(isink))
        alpha=max((densc(isink)/d_star)**2,1d0)
        factor=alpha*fudge*densc(isink)*msink(isink)/c2sink_all(isink) / vnorm_rel
        if(mach.le.0.950d0)factor=factor/mach**2*(0.5d0*log((1d0+mach)/(1d0-mach))-mach)
        if(mach.ge.1.007d0)factor=factor/mach**2*(0.5d0*log(mach**2-1d0)+3.2d0)
        factor=MIN(factor,2.0d0/(dtnew(ilevel)+dteff))
        fdrag(isink,1:ndim)=-factor*vrel(1:ndim)
        ! Compute new sink velocity due to the drag
        vsink(isink,1:ndim)=0.5D0*(dtnew(ilevel)+dteff)*fdrag(isink,1:ndim)+vsink(isink,1:ndim)
        ! save the velocity
        vsnew(isink,1:ndim,ilevel)=vsink(isink,1:ndim)
     endif

     ! and this is the drift (only for the global sink variable)
     xsink(isink,1:ndim)=xsink(isink,1:ndim)+vsink(isink,1:ndim)*dtnew(ilevel)
     new_born(isink)=.false.
  end do
  sinkint_level=ilevel
  

#endif
end subroutine update_sink
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine update_cloud(ilevel)
  use amr_commons
  use pm_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel

  !----------------------------------------------------------------------
  ! update sink cloud particle properties
  ! -the particles are moved whenever the level of the grid they sit in is updated
  ! -the amount of drift they get is according to their levelp
  ! -since this is happening on the way down, at level ilevel all particles with
  ! level >= ilevel will be moved. Therefore, the sink_jump for all levels >= ilevel
  ! is set ot zero on exit.
  !----------------------------------------------------------------------

  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,npart1,isink,nx_loc
  integer,dimension(1:nvector)::ind_grid,ind_part,ind_grid_part
  real(dp)::dx,dx_loc,scale,vol_loc
  real(dp),dimension(1:3)::skip_loc


  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim

  ! Update particles position and velocity
  ig=0
  ip=0
  ! Loop over grids 
  igrid=headl(myid,ilevel)
  do jgrid=1,numbl(myid,ilevel)
     npart1=numbp(igrid)  ! Number of particles in the grid 
     if(npart1>0)then
        ig=ig+1
        ind_grid(ig)=igrid
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle  <---- Very important !!!
           next_part=nextp(ipart) !move only particles which do actually belong to that level
           if(ig==0)then
              ig=1
              ind_grid(ig)=igrid
           end if
           ip=ip+1
           ind_part(ip)=ipart
           ind_grid_part(ip)=ig
           if(ip==nvector)then
              call upd_cloud(ind_part,ip)
              ip=0
              ig=0
           end if
           ipart=next_part  ! Go to next particle
        end do
        ! End loop over particles
     end if
     igrid=next(igrid)   ! Go to next grid
  end do
  ! End loop over grids
  if(ip>0)call upd_cloud(ind_part,ip)
  
  if (myid==1.and.verbose)then
     write(*,*)'sink drift due to accretion relative to grid size at level ',ilevel
     do isink=1,nsink
        write(*,*),'#sink: ',isink,' drift: ',sink_jump(isink,1:ndim,ilevel)/dx_loc
     end do
  end if

  sink_jump(1:nsink,1:ndim,ilevel:nlevelmax)=0.d0

111 format('   Entering update_cloud for level ',I2)

end subroutine update_cloud
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine upd_cloud(ind_part,np)
  use amr_commons
  use pm_commons
  use poisson_commons
  implicit none
  integer::np
  integer,dimension(1:nvector)::ind_part

  !------------------------------------------------------------
  ! Vector loop called by update_cloud
  !------------------------------------------------------------

  integer::j,idim,isink,lev
  real(dp),dimension(1:nvector,1:ndim)::new_xp,new_vp
  integer,dimension(1:nvector)::level_p

  ! Overwrite cloud particle mass with sink mass
  do j=1,np
     isink=-idp(ind_part(j))
     if(isink>0 .and. mp(ind_part(j))>0.)then
        mp(ind_part(j))=msink(isink)/dble(ncloud_sink_massive)
     endif
  end do

  ! store velocity 
  do idim=1,ndim
     do j=1,np
        new_vp(j,idim)=vp(ind_part(j),idim)
     end do
  end do

  ! Overwrite cloud particle velocity with sink velocity  
  ! is going to be overwritten again before move
  do idim=1,ndim
     do j=1,np
        isink=-idp(ind_part(j))
        if(isink>0)then
              new_vp(j,idim)=vsink(isink,idim)
        end if
     end do
  end do

  ! write back velocity
  do idim=1,ndim
     do j=1,np
        vp(ind_part(j),idim)=new_vp(j,idim)
     end do
  end do

  ! read level
  do j=1,np
     level_p(j)=levelp(ind_part(j))
  end do
 
  ! Update position
  do idim=1,ndim
     do j=1,np
        new_xp(j,idim)=xp(ind_part(j),idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        isink=-idp(ind_part(j))
        if(isink>0)then
           lev=level_p(j)
           new_xp(j,idim)=new_xp(j,idim)+sink_jump(isink,idim,lev)
        endif
     end do
  end do
 
 ! Write back postion
  do idim=1,ndim
     do j=1,np
        xp(ind_part(j),idim)=new_xp(j,idim)
     end do
  end do

end subroutine upd_cloud
!################################################################
!################################################################
!################################################################
!################################################################
subroutine merge_star_sink
  use pm_commons
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !------------------------------------------------------------------------
  ! This routine merges sink particles for the star formation case if 
  ! they are too close and one of them is younger than ~1000 years
  !------------------------------------------------------------------------

  integer::j,isink,jsink,i,nx_loc,mergers
  real(dp)::dx_loc,scale,dx_min,rr,rmax2,rmax,mnew,t_larson1
  real(dp),dimension(1:3)::skip_loc
  logical::iyoung,jyoung,merge
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v



  if(nsink==0)return

  ! Mesh spacing in that level
  dx_loc=0.5D0**nlevelmax
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp
  rmax=dble(ir_cloud)*dx_min ! Linking length in physical units
  rmax2=rmax*rmax

  !lifetime of first larson core in code units 
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  t_larson1=merging_timescale*365.25*24*3600/scale_t

  mergers=0
  !loop over all possible pairs (n-square, problematic when there are zilions of sinks)
  do isink=1,nsink-1
     if (msink(isink)>-1.)then
        do jsink=isink+1,nsink
           iyoung=(t-tsink(isink)<t_larson1)
           jyoung=(t-tsink(jsink)<t_larson1)

           rr=(xsink(isink,1)-xsink(jsink,1))**2&
                +(xsink(isink,2)-xsink(jsink,2))**2&
                +(xsink(isink,3)-xsink(jsink,3))**2
           
           merge=(iyoung .or. jyoung).and.rr<rmax2
           merge=merge .or. (iyoung .and. jyoung .and. rr<4*rmax2)
           merge=merge .and. msink(jsink)>=0
           

           if (merge)then
              if (myid==1)write(*,*)'merged ', idsink(jsink),' to ',idsink(isink)
              mergers=mergers+1
              mnew=msink(isink)+msink(jsink)
              xsink(isink,1:3)=(xsink(isink,1:3)*msink(isink)+xsink(jsink,1:3)*msink(jsink))/mnew
              vsink(isink,1:3)=(vsink(isink,1:3)*msink(isink)+vsink(jsink,1:3)*msink(jsink))/mnew
              !wrong! Angular momentum is most likely dominated by last merger, change some day...
              lsink(isink,1:3)=lsink(isink,1:3)+lsink(jsink,1:3)
              msink(isink)=mnew

              acc_rate(isink)=acc_rate(isink)+msink(jsink)
              !acc_lum is recomputed anyway before its used
              acc_lum(isink)=ir_eff*acc_rate(isink)/dtnew(levelmin)*msink(isink)/(5*6.955d10/scale_l)

              msink(jsink)=-10.
              tsink(isink)=min(tsink(isink),tsink(jsink))
              idsink(isink)=min(idsink(isink),idsink(jsink))
           endif
        end do
     end if
  end do

  if (myid==1 .and. mergers>0)write(*,*)'merged ',mergers,' sinks'

  i=1
  do while (mergers>0)

     if (msink(i)<-1.)then !if sink has been merged to another one        

        mergers=mergers-1
        nsink=nsink-1

        !let them all slide back one index
        do j=i,nsink
           xsink(j,1:3)=xsink(j+1,1:3)
           vsink(j,1:3)=vsink(j+1,1:3)
           lsink(j,1:3)=lsink(j+1,1:3)
           msink(j)=msink(j+1)
           tsink(j)=tsink(j+1)
           idsink(j)=idsink(j+1)
           acc_rate(j)=acc_rate(j+1)
           acc_lum(j)=acc_lum(j+1)
        end do

        !whipe last position in the sink list
        xsink(nsink+1,1:3)=0.
        vsink(nsink+1,1:3)=0.
        lsink(nsink+1,1:3)=0.
        msink(nsink+1)=0.
        tsink(nsink+1)=0.
        idsink(nsink+1)=0
        acc_rate(nsink+1)=0.
        acc_lum(nsink+1)=0.

     else
        i=i+1
     end if
  end do

end subroutine merge_star_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine divergence_sink(ind_part,divs,np)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::np
  integer,dimension(1:nvector)::ind_part
  real(dp),dimension(1:nsinkmax)::divs

  !--------------------------------------------------------------------------------
  ! this routine computes the divergence of rho*(v-vsink) and for nvector particles
  !--------------------------------------------------------------------------------

  integer::i,j,nx_loc,isink,divdim,ilevel,idim
  real(dp)::dx,scale,dx_min,one_over_dx_min
  real(dp),dimension(1:nvector,1:ndim)::xleft,xright,xpart
  integer,dimension(1:nvector)::clevl,cind_right,cind_left,cind_part
  real(dp),dimension(1:3)::skip_loc
  logical ,dimension(1:nvector)::ok

  ilevel=nlevelmax
  ok=.true.

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp
  one_over_dx_min=1./dx_min

  do idim=1,ndim
     !position of the particle                                                                                                                         
     do i=1,np
        xpart(i,idim)=xp(ind_part(i),idim)
     enddo
  end do


!  ! pretty cheap way to handle multiple sinks overlapping. only the first 8 cloud
!  ! parts are allowd to accrete (heavier sink will win)
!  call get_cell_index(cind_part,clevl,xpart,ilevel,np)
!  do i=1,np
!     flag2(cind_part(i))=flag2(cind_part(i))+1
!     ok(i)=(flag2(cind_part(i)) .le. 8)
!  end do
  do divdim=1,3
     !use cell spacing to get left and right position
     do i=1,np
        xleft(i,divdim)=xpart(i,divdim)-dx_min   
        xright(i,divdim)=xpart(i,divdim)+dx_min
     end do

     call get_cell_index(cind_right,clevl,xright,ilevel,np)
     call get_cell_index(cind_left,clevl,xleft,ilevel,np)
     
     do j=1,np
        if(ok(j))then
           isink=-idp(ind_part(j))
           !compute divergence of (rho*v - rho*vsink) in one go
           divs(isink)=divs(isink)+(uold(cind_right(j),divdim+1)-uold(cind_right(j),1)*vsink(isink,divdim)-&
                uold(cind_left(j),divdim+1)+uold(cind_left(j),1)*vsink(isink,divdim))*one_over_dx_min*0.5 
        end if
     end do
  end do
  
end subroutine divergence_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine f_gas_sink(ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  use poisson_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif 
 integer::ilevel
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 
  ! In this subroutine the sink-gas force contributions are calculated.  
  ! A plummer-sphere with radius ssoft is used for softening   
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 
  integer::igrid,ngrid,ncache,i,ind,iskip,ix,iy,iz,isink
  integer::info,nx_loc,idim
  real(dp)::dx,dx_loc,scale,vol_loc
  real(dp),dimension(1:twotondim,1:3)::xc
  real(dp),dimension(1:3)::skip_loc
  
  logical ,dimension(1:nvector)::ok
  integer ,dimension(1:nvector)::ind_grid,ind_cell
  real(dp),dimension(1:nvector,1:ndim)::xx,ff
  real(dp),dimension(1:nvector)::d2,mcell

  !  Cell spacing at that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim

  ! Set position of cell centers relative to grid cente
  do ind=1,twotondim
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     if(ndim>0)xc(ind,1)=(dble(ix)-0.5D0)*dx
     if(ndim>1)xc(ind,2)=(dble(iy)-0.5D0)*dx
     if(ndim>2)xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do

  fsink_new=0.
  ! Loop over sinks 
  do isink=1,nsink
     if (direct_force_sink(isink))then
        ! Loop over myid grids by vector sweeps
        ncache=active(ilevel)%ngrid
        do igrid=1,ncache,nvector
           ngrid=MIN(nvector,ncache-igrid+1)
           do i=1,ngrid
              ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
           end do

           ! Loop over cells
           do ind=1,twotondim
              iskip=ncoarse+(ind-1)*ngridmax
              do i=1,ngrid
                 ind_cell(i)=iskip+ind_grid(i)
              end do

              !check if cell is refined
              do i=1,ngrid
                 ok(i)=son(ind_cell(i))==0
              end do

              !gas mass in cell
              do i=1,ngrid
                 mcell(i)=rho(ind_cell(i))*vol_loc
              end do

              !Cell center
              do idim=1,ndim
                 do i=1,ngrid
                    xx(i,idim)=(xg(ind_grid(i),idim)+xc(ind,idim)-skip_loc(idim))*scale
                 end do
              end do

              d2=0.d0
              do idim=1,ndim        
                 do i=1,ngrid
                    ff(i,idim)=xsink(isink,idim)-xx(i,idim)
                    d2(i)=d2(i)+ff(i,idim)**2
                 end do
              end do
              !compute force onto gas cell due to sink
              do i=1,ngrid
                 ff(i,1:ndim)=mcell(i)*msink(isink)/(ssoft**2+d2(i))**1.5*ff(i,1:ndim)
              end do
              !add gas acceleration due to sink
              do i=1,ngrid
                 f(ind_cell(i),1:ndim)=f(ind_cell(i),1:ndim)+ff(i,1:ndim)/mcell(i)
              end do
              !change maximum level potential due to sink (correct for BOXLEN???)
              !coution: this is wrong if the potential is used as boudary condition for finer levels, 
              !therefore this is only done at levelmax. Keep in mind that phi is therefore only correct at that level
              if (ilevel==nlevelmax)then
                 do i=1,ngrid
                    phi(ind_cell(i))=phi(ind_cell(i))-msink(isink)/(ssoft**2+d2(i))**0.5
                 end do
              end if
              !add sink acceleration due to gas
              do i=1,ngrid
                 if (ok(i))then
                    fsink_new(isink,1:ndim)=fsink_new(isink,1:ndim)-ff(i,1:ndim)/msink(isink)
                 end if
              end do
           end do !end loop over cells
        end do !end loop over grids
     end if !end if direct force
  end do !end loop over sinks

  !collect sink acceleration from cpus
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(fsink_new,fsink_all,nsinkmax*ndim,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,info)
#else
     fsink_all=fsink_new
#endif
  do isink=1,nsink
     if (direct_force_sink(isink))then
        fsink_partial(isink,1:ndim,ilevel)=fsink_all(isink,1:ndim)
     end if
  end do  

  do idim=1,ndim
     call make_virtual_fine_dp(f(1,idim),ilevel)
  end do
  if (ilevel==nlevelmax)call make_virtual_fine_dp(phi(1),ilevel)
  
end subroutine f_gas_sink

!################################################################
!################################################################
!################################################################
!################################################################
subroutine f_sink_sink
  use amr_commons
  use pm_commons  
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ! In this subroutine the sink-sink force contribution are calculated by direct
  ! n^2 - summation. A plummer-sphere with radius 4 cells is used for softening
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  integer::isink,idim,jsink,i,info
  real(dp),allocatable,dimension(:)::d2
  real(dp),allocatable,dimension(:,:)::ff

  allocate(d2(1:nsink))
  allocate(ff(1:nsink,1:ndim))
  
  fsink=0.
  
  do isink=1,nsink
     if (direct_force_sink(isink))then
        d2=0.d0
        ff=0.d0
        do idim=1,ndim
           !compute relative position and and distances
           do jsink=1,nsink
              if (direct_force_sink(jsink))then           
                 ff(jsink,idim)=xsink(jsink,idim)-xsink(isink,idim)
                 d2(jsink)=d2(jsink)+ff(jsink,idim)**2
              end if
           end do
        end do
        !compute acceleration
        do jsink=1,nsink
           if (direct_force_sink(jsink))then
              ff(jsink,1:ndim)=msink(jsink)/(ssoft**2+d2(jsink))**1.5*ff(jsink,1:ndim)
           end if
        end do
        do jsink=1,nsink           
           fsink(isink,1:ndim)=fsink(isink,1:ndim)+ff(jsink,1:ndim)
           if(jsink<0)then
              print*,'This is just a stupid trick to prevent'
              print*,'the compiler from optimizing this loop!'
           end if
        end do             
     end if
  end do
end subroutine f_sink_sink
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine read_sink_params()
  use pm_commons
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  

  real(dp)::dx_min,scale,cty
  integer::nx_loc
  namelist/sink_params/n_sink,rho_sink,accretion_scheme,nol_accretion,merging_scheme,merging_timescale,&
       ir_cloud_massive,sink_soft,msink_direct,ir_cloud,nsinkmax,c_acc
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)  

  nx_loc=(icoarse_max-icoarse_min+1)
  scale = boxlen/dble(nx_loc)


  ! Read namelist file 
  rewind(1)
  read(1,NML=sink_params,END=111)
  goto 112
111 if(myid==1)write(*,*)'You did not set up &SINK_PARAMS in the namelist file'
  if(myid==1)write(*,*)'Using default values '

112 rewind(1)
  
  !check for accretion scheme
  if (accretion_scheme =='flux')then
     use_acc_rate=.true.
     flux_accretion=.true.
  end if
  if (accretion_scheme =='bondi')then
     use_acc_rate=.true.
     flux_accretion=.false.
  end if
  if (accretion_scheme =='threshold_accretion')then
     use_acc_rate=.false.
     flux_accretion=.false.
     threshold_accretion=.true.
  end if


  ! check for threshold  
  if (n_sink<0. .and. cosmo)then
     if(myid==1)write(*,*)'specify n_sink for a cosmological simulation'
     call clean_stop
  end if

  if (rho_sink>0. .and. n_sink<0.)then
     d_sink=rho_sink/scale_d
  else if (rho_sink<0. .and. n_sink>0.)then
     d_sink=n_sink/scale_nH
  else if (rho_sink>0. .and. n_sink>0.)then
     if (myid==1)write(*,*)'Use n_sink [H/cc] OR rho_sink [g/cc]'
     call clean_stop
  else
     if(myid==1)write(*,*)'Setting sink threshold such that jeans length at '
     if(myid==1)write(*,*)'max resolution is resolved by 4 cells, assuming isothermal gas'
     if(T2_star==0.)then 
        if(myid==1)write(*,*)'No value for T2_star given. Do not know what to do...'
        call clean_stop
     else
        dx_min=0.5**nlevelmax*scale
        d_sink=T2_star/scale_T2 *3.14159/16./(dx_min**2)
     end if
  end if

  if (merging_scheme == 'timescale' .and. merging_timescale<0.)then
     if (myid==1)write(*,*)'You chose sink merging on a timescale but did not provide the timescale'
     if (myid==1)write(*,*)'choosing 1000y as lifetime...'
     merging_timescale=1000.
     cty=scale_t/(365.25*24.*3600.)
     cont_speed=1./(merging_timescale/cty)
  end if
  
  ! nol_accretion requires a somewhat smaller timestep per default
  if(c_acc < 0.)then
     if (nol_accretion)then
        c_acc=0.25
     else
        c_acc=0.75
     end if
  end if


end subroutine read_sink_params
!################################################################
!################################################################
!################################################################
!################################################################
subroutine count_clouds(ilevel,action)
  use pm_commons
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel
  character(len=15)::action
  !------------------------------------------------------------------------

  !------------------------------------------------------------------------

  integer::igrid,jgrid,ipart,jpart,next_part,info,ind,jlevel
  integer::ig,ip,npart1,npart2,icpu,nx_loc,isink
  integer,dimension(1:nvector)::cc,cell_index,cell_levl,ind_grid,ind_part,ind_grid_part
  real(dp),dimension(1:nvector,1:3)::xpart
  real(dp)::dx_loc,dx_min,scale,factG
  real(dp),dimension(1:nsinkmax)::divs, divs_tot

  if(numbtot(1,ilevel)==0)return
  
  ! Mesh spacing in that level
  dx_loc=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=scale*0.5D0**nlevelmax/aexp

  !use flag2 to count the cloud particles per cell
  !to handle accretion onto multiple sinks from one cell
  if (action=='count')flag2=0
  
  ! Loop over cpus
  do icpu=1,ncpu
     igrid=headl(icpu,ilevel)
     ig=0
     ip=0
     ! Loop over grids
     do jgrid=1,numbl(icpu,ilevel)
        npart1=numbp(igrid)  ! Number of particles in the grid
        npart2=0
        
        ! Count sink and cloud particles
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              if(idp(ipart).lt.0)then
                 npart2=npart2+1
              endif
              ipart=next_part  ! Go to next particle
           end do
        endif
        
        ! Gather sink and cloud particles
        if(npart2>0)then        
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle   <--- Very important !!!
              next_part=nextp(ipart)
              ! Select only sink particles
              if(idp(ipart).lt.0)then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig   
              endif
              if(ip==nvector)then
                 call count_clouds_np(ind_part,ip,action,ilevel)
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do

     ! End loop over grids
     if(ip>0)then
        call count_clouds_np(ind_part,ip,action,ilevel)
     end if
  end do
  ! End loop over cpus

end subroutine count_clouds
!################################################################
!################################################################
!################################################################
!################################################################
subroutine count_clouds_np(ind_part,np,action,ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  implicit none
  integer::np,ilevel
  integer,dimension(1:nvector)::ind_part
  real(dp),dimension(1:nsinkmax)::divs
  character(len=15)::action
  !--------------------------------------------------------------------------------
  ! 
  !--------------------------------------------------------------------------------
  
  integer::i,nx_loc,isink,divdim,idim
  real(dp)::dx,scale,dx_min,one_over_dx_min,weight,r2,parts_per_cell,vol_min
  real(dp),dimension(1:nvector,1:ndim)::xleft,xright,xpart
  integer,dimension(1:nvector)::clevl,cind_right,cind_left,cind_part
  real(dp),dimension(1:3)::skip_loc
  logical ,dimension(1:nvector)::ok
  
  nx_loc=(icoarse_max-icoarse_min+1)
  scale=boxlen/dble(nx_loc)
  dx_min=(0.5D0**nlevelmax)*scale
  vol_min=dx_min**ndim
  
  
  do idim=1,ndim
     do i=1,np
        xpart(i,idim)=xp(ind_part(i),idim)
     enddo
  end do
  call get_cell_index(cind_part,clevl,xpart,nlevelmax,np)
  
  if (action=='count')then
     do i=1,np
        flag2(cind_part(i))=flag2(cind_part(i))
     end do
  end if
  
  if (action=='weight')then
     do i=1,np
        isink=-idp(ind_part(i))
        parts_per_cell=8*8.**(nlevelmax-clevl(i))
        !        if (flux_accretion)then
        if (flag2(cind_part(i))>parts_per_cell)then
           weight=parts_per_cell/flag2(cind_part(i))
        else           
           weight=1.
        end if
        weight=weight*vol_min/8.
        !        else ! weight for bondi accretion kernel
        !           r2=0d0
        !           do idim=1,ndim
        !              r2=r2+(xp(ind_part(i),idim)-xsink(isink,idim))**2
        !           end do
        !           weight=exp(-r2/r2k(isink))
        !        end if

        
        weightp(ind_part(i))=weight     
     end do

     if(threshold_accretion)then
        do i=1,np
           if(uold(cind_part(i),1)<d_sink)then
              weightp(ind_part(i))=0.
           end if
        end do
     end if
     
  end if
  
end subroutine count_clouds_np
