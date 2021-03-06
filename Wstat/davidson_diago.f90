!
! Copyright (C) 2015-2017 M. Govoni 
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
! This file is part of WEST.
!
! Contributors to this file: 
! Marco Govoni
!
#define ZERO ( 0.D0, 0.D0 )
#define ONE  ( 1.D0, 0.D0 )
!
!----------------------------------------------------------------------------
SUBROUTINE davidson_diago ( )
  !----------------------------------------------------------------------------
  !
  USE control_flags,   ONLY : gamma_only 
  !
  IMPLICIT NONE
  !
  IF( gamma_only ) THEN 
    CALL davidson_diago_gamma( ) 
  ELSE
    CALL davidson_diago_k( )
  ENDIF 
  !
END SUBROUTINE 
!
!----------------------------------------------------------------------------
SUBROUTINE davidson_diago_gamma ( )
  !----------------------------------------------------------------------------
  !
  ! ... iterative solution of the eigenvalue problem:
  ! ... ( chi - ev ) * dvg = 0
  !
  USE kinds,                ONLY : DP
  USE io_global,            ONLY : stdout
  USE distribution_center,  ONLY : pert
  USE class_idistribute,    ONLY : idistribute
  USE io_push,              ONLY : io_push_title,io_push_bar
  USE westcom,              ONLY : dvg,dng,n_pdep_eigen,trev_pdep,n_pdep_maxiter,n_pdep_basis,wstat_calculation,ev,conv,&
                                   & n_pdep_restart_from_itr,n_pdep_read_from_file,n_steps_write_restart,n_pdep_times,npwqx,npwq,&
                                   & npwqx,npwq,trev_pdep_rel,tr2_dfpt,l_is_wstat_converged,fftdriver
  USE pdep_db,              ONLY : pdep_db_write,pdep_db_read
  USE wstat_restart,        ONLY : wstat_restart_write, wstat_restart_clear, wstat_restart_read
  USE mp_world,             ONLY : mpime
  USE mp_global,            ONLY : inter_image_comm
  USE mp,                   ONLY : mp_sum
  USE gvect,                ONLY : gstart
  USE wstat_tools,          ONLY : diagox,serial_diagox,build_hr,symm_hr_distr,redistribute_vr_distr,&
                                   & update_with_vr_distr,refresh_with_vr_distr 
  USE types_coulomb,        ONLY : pot3D
  !
  IMPLICIT NONE
  !
  ! ... LOCAL variables
  !
  INTEGER :: nvec, nvecx
    ! dimension of the matrix to be diagonalized
    ! leading dimension of matrix evc, as declared in the calling pgm unit
  INTEGER :: dav_iter, notcnv
    ! integer  number of iterations performed
    ! number of unconverged roots
  INTEGER :: kter, nbase, np, n, m
    ! counter on iterations
    ! dimension of the reduced basis
    ! counter on the reduced basis vectors
    ! do-loop counters
    ! counter on the bands
  INTEGER :: ierr,mloc,mstart,mend
  INTEGER,ALLOCATABLE :: ishift(:)
  REAL(DP), ALLOCATABLE :: ew(:)
  REAL(DP), ALLOCATABLE :: hr_distr(:,:), vr_distr(:,:)
  !
  INTEGER :: il1,il2,ig1,ig2,i
  REAL(DP) :: time_spent(2)
  INTEGER :: sternop_ncalls(2)
  CHARACTER(LEN=8) :: iter_label
  REAL(DP) :: pccg_res_tr2
  INTEGER :: dfpt_dim, diago_dim
  !
  REAL(DP), EXTERNAL :: GET_CLOCK
  !
  ! ... INITIALIZATION
  !
  l_is_wstat_converged = .FALSE.
  nvec = n_pdep_eigen
  nvecx = n_pdep_basis
  !
  CALL start_clock( 'chidiago' )
  time_spent(1)=get_clock( 'chidiago' )
  CALL get_clock_called( 'stern' , sternop_ncalls(1) )
  !
  ! ... DISTRIBUTE nvecx
  !
  pert = idistribute()
  CALL pert%init(nvecx,'i','nvecx',.TRUE.)
  !CALL index_distr_init(pert,nvecx,'i','nvecx',.TRUE.) 
  CALL wstat_memory_report() ! Before allocating I report the memory required. 
  !
  ! ... MEMORY ALLOCATION
  !
  IF ( nvec > nvecx / 2 ) CALL errore( 'chidiago', 'nvecx is too small', 1 )
  !
  ALLOCATE( dvg( npwqx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate dvg ', ABS(ierr) )
  !
  ALLOCATE( dng( npwqx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate dng ', ABS(ierr) )
  !
  ALLOCATE( hr_distr( nvecx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate hr_distr ', ABS(ierr) )
  !
  ALLOCATE( vr_distr( nvecx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate vr_distr ', ABS(ierr) )
  !
  ALLOCATE( ew( nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate ew ', ABS(ierr) )
  !
  ALLOCATE( ev( nvec  ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate ev ', ABS(ierr) )
  !
  ALLOCATE( conv( nvec ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate conv ', ABS(ierr) )
  !
  nbase  = nvec
  conv   = .FALSE.
  ev     = 0._DP
  ew     = 0._DP
  dng  = 0._DP
  dvg  = 0._DP
  hr_distr(:,:) = 0._DP
  vr_distr(:,:) = 0._DP
  notcnv  = nvec 
  dav_iter = -2
  !
  CALL pot3D%init(fftdriver,.FALSE.,'default')
  CALL pot3d%print_divergence()
  !
  ! KIND OF CALCULATION
  !
  IF( wstat_calculation(1:1)=="R" .OR. wstat_calculation(2:2)=="R" ) THEN
     !
     ! RESTART
     !
     CALL wstat_restart_read( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr )
     !
  ENDIF
  IF( wstat_calculation(1:1)=="S" .OR. wstat_calculation(2:2)=="S" ) THEN
     !
     ! FROM SCRATCH
     !
     ! ... Eventually read from file
     !
     IF(n_pdep_read_from_file>0) CALL pdep_db_read( n_pdep_read_from_file )
     !
     ! ... Eventually randomize
     !
     IF(n_pdep_read_from_file<nvec) CALL do_randomize ( dvg, n_pdep_read_from_file+1, nvec )
     !
     ! ... MGS
     !
     CALL do_mgs( dvg, 1, nvec)
     !
     dfpt_dim = nbase
     diago_dim = nbase
     WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
     WRITE(stdout, &
         & "(   5x,'#     Iteration = | ', a8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |  x 1/2')")&
         & 'starting', dfpt_dim, diago_dim
     WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
     !
     ! Apply operator with DFPT
     !
     mloc = 0
     mstart = 1 
     DO il1 = 1, pert%nloc
        ig1 = pert%l2g(il1)
        IF( ig1 < 1 .OR. ig1 > nvec ) CYCLE
        IF( mloc==0 ) mstart = il1
        mloc = mloc + 1
     ENDDO
     !
     pccg_res_tr2 = -1._DP
     CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2, 1 ) 
     dav_iter = -1
     CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr)
     !
  ENDIF
  !
  IF( dav_iter == -2 ) CALL errore( 'chidiago','Cannot find the 1st starting loop',1) 
  !
  IF( dav_iter == -1 ) THEN
     !
     ! < EXTRA STEP > 
     !
     dvg = dng
     CALL do_mgs( dvg, 1, nvec)
     !
     dfpt_dim = nbase
     diago_dim = nbase
     WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
     WRITE(stdout, &
         & "(   5x,'#     Iteration = | ', a8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |  x 2/2')")&
         & 'starting', dfpt_dim, diago_dim
     WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
     !
     ! Apply operator with DFPT
     !
     mloc = 0
     mstart = 1 
     DO il1 = 1, pert%nloc
        ig1 = pert%l2g(il1)
        IF( ig1 < 1 .OR. ig1 > nvec ) CYCLE
        IF( mloc==0 ) mstart = il1
        mloc = mloc + 1
     ENDDO
     !
     pccg_res_tr2 = MIN(0.01_DP,1000000._DP*tr2_dfpt)
     CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2 ) 
     ! 
     ! </ EXTRA STEP >
     !
     ! hr = <dvg|dng>
     !
     CALL build_hr( dvg, dng, mstart, mstart+mloc-1, hr_distr, 1, nvec ) 
     !
     ! ... diagonalize the reduced hamiltonian
     !
     CALL diagox( nbase, nvec, hr_distr, nvecx, ew, vr_distr )
     time_spent(2)=get_clock( 'chidiago' )
     CALL get_clock_called( 'stern' , sternop_ncalls(2) )
     ev(1:nvec) = ew(1:nvec)
     !
     ! Write the eigenvalues & time spent
     !
     CALL output_ev_and_time(nvec,ev,conv,time_spent,sternop_ncalls,pccg_res_tr2,dfpt_dim,diago_dim,dav_iter,notcnv)
     dav_iter = 0
     CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr)
     !
  ENDIF
  !
  ! --------------------
  !
  ! ... iterate
  !
  ! --------------------
  !
  iterate: DO kter = 1, n_pdep_maxiter
     !
     time_spent(1) = get_clock( 'chidiago' )
     CALL get_clock_called( 'stern' , sternop_ncalls(1) )
     !
     dav_iter = dav_iter + 1
     !
     dfpt_dim = notcnv
     diago_dim = nbase+notcnv
     WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
     WRITE(stdout, "(   5x,'#     Iteration = | ', i8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |')") &
         &dav_iter, dfpt_dim, diago_dim
     WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
     !
     ALLOCATE( ishift( nvecx ), STAT=ierr )
     IF( ierr /= 0 ) CALL errore( 'chidiago',' cannot allocate ishift ', ABS(ierr) )
     ishift=0
     np = 0
     !
     DO n = 1, nvec
        !
        IF ( .NOT. conv(n) ) THEN
           !
           ! ... this root not yet converged ... 
           !
           np = np + 1
           !
           ! ... reorder eigenvectors so that coefficients for unconverged
           ! ... roots come first. This allows to use quick matrix-matrix 
           ! ... multiplications to set a new basis vector (see below)
           !
           !IF ( np /= n ) vr(:,np) = vr(:,n)
           ishift(nbase+np) = n
           !
           ew(nbase+np) = ev(n)
           !   
        END IF
        !
     END DO
     !
     ! ... expand the basis set with new basis vectors ( H - e*S )|psi> ...
     !
     CALL redistribute_vr_distr( notcnv, nbase, nvecx, vr_distr, ishift )
     DEALLOCATE(ishift)
     CALL update_with_vr_distr( dvg, dng, notcnv, nbase, nvecx, vr_distr, ew )
     !
     ! ... MGS
     !
     CALL do_mgs(dvg,nbase+1,nbase+notcnv)
     !
     ! apply the response function to new vectors
     !
     ! determine image that actually compute dng first
     !
     mloc = 0 
     mstart = 1
     DO il1 = 1, pert%nloc
        ig1 = pert%l2g(il1)
        IF( ig1 < nbase+1 .OR. ig1 > nbase+notcnv ) CYCLE
        IF( mloc==0 ) mstart = il1
        mloc = mloc + 1
     ENDDO
     !
     ! Apply operator with DFPT
     !
     pccg_res_tr2 = tr2_dfpt
     CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2, 1) 
     !
     ! ... update the reduced hamiltonian
     !
     !
     ! hr = <dvg|dng>
     !
     CALL build_hr( dvg, dng, mstart, mstart+mloc-1, hr_distr, nbase+1, nbase+notcnv ) 
     !
     nbase = nbase + notcnv
     !
     CALL symm_hr_distr(hr_distr,nbase,nvecx)
     !
     ! ... diagonalize the reduced hamiltonian
     !
     CALL diagox( nbase, nvec, hr_distr, nvecx, ew, vr_distr )
     time_spent(2)=get_clock( 'chidiago' )
     CALL get_clock_called( 'stern' , sternop_ncalls(2) )
     !
     ! ... test for convergence
     !
     conv(1:nvec) = ( ( ABS( (ew(1:nvec) - ev(1:nvec))/ev(1:nvec) ) < trev_pdep_rel ) &
                 .AND. ( ABS( ew(1:nvec) - ev(1:nvec) ) < trev_pdep ) )
     !conv(1:nvec) = ( ( ABS( ew(1:nvec) - ev(1:nvec) ) < trev_pdep ) )
     !
     notcnv = COUNT( .NOT. conv(:) )
     !
     ev(1:nvec) = ew(1:nvec)
     !
     ! Write the eigenvalues & time spent
     !
     CALL output_ev_and_time(nvec,ev,conv,time_spent,sternop_ncalls,pccg_res_tr2,dfpt_dim,diago_dim,dav_iter,notcnv)
     !
     ! ... if overall convergence has been achieved, or the dimension of
     ! ... the reduced basis set is becoming too large, or in any case if
     ! ... we are at the last iteration refresh the basis set. i.e. replace
     ! ... the first nvec elements with the current estimate of the
     ! ... eigenvectors;  set the basis dimension to nvec.
     !
     IF ( notcnv == 0 .OR. nbase+notcnv > nvecx .OR. kter == n_pdep_maxiter ) THEN
        !
        CALL start_clock( 'chidiago:last' )
        !
        IF ( notcnv == 0 ) THEN
           !
           ! ... all roots converged: return
           !
           CALL stop_clock( 'chidiago:last' )
           !
           CALL refresh_with_vr_distr( dvg, nvec, nbase, nvecx, vr_distr )
           !
           CALL pdep_db_write( )
           CALL wstat_restart_clear()
           !CALL output_a_report(-1)
           !
           WRITE(iter_label,'(i8)') kter
           CALL io_push_title("Convergence achieved !!! in "//TRIM(iter_label)//" steps") 
           l_is_wstat_converged = .TRUE.
           !
           EXIT iterate
           !
        ELSE IF ( kter == n_pdep_maxiter ) THEN
           !
           ! ... last iteration, some roots not converged: return
           !
           WRITE( stdout, '(5X,"WARNING: ",I5, &
                &   " eigenvalues not converged in chidiago")' ) notcnv
           !
           CALL stop_clock( 'chidiago:last' )
           !
           EXIT iterate
           !
        END IF
        !
        ! ... refresh psi, H*psi and S*psi
        !
        WRITE(stdout,'(/,7x,"Refresh the basis set")')
        !
        CALL refresh_with_vr_distr( dvg, nvec, nbase, nvecx, vr_distr )
        CALL refresh_with_vr_distr( dng, nvec, nbase, nvecx, vr_distr )
        !
        ! ... refresh the reduced hamiltonian
        !
        nbase = nvec
        !
        hr_distr = 0._DP
        vr_distr = 0._DP
        !
        DO il1 = 1, pert%nloc
           ig1 = pert%l2g(il1)
           IF( ig1 > nbase ) CYCLE 
           hr_distr(ig1,il1) = ev(ig1)
           vr_distr(ig1,il1) = 1._DP
        ENDDO
        !
        CALL stop_clock( 'chidiago:last' )
        !
     END IF
     !
     CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr)
     !CALL output_a_report(dav_iter)
     !
  END DO iterate
  !
  !
  DEALLOCATE( conv )
  DEALLOCATE( ew )
  DEALLOCATE( ev )
  DEALLOCATE( hr_distr )
  DEALLOCATE( vr_distr )
  !
  !
  DEALLOCATE( dng )
  DEALLOCATE( dvg )  
  !
  CALL stop_clock( 'chidiago' )
  !
  RETURN
  !
END SUBROUTINE
!
!----------------------------------------------------------------------------
SUBROUTINE davidson_diago_k ( )
  !----------------------------------------------------------------------------
  !
  ! ... iterative solution of the eigenvalue problem:
  ! ... ( chi - ev ) * dvg = 0
  !
  USE kinds,                ONLY : DP
  USE io_global,            ONLY : stdout
  USE distribution_center,  ONLY : pert
  USE class_idistribute,    ONLY : idistribute
  USE io_push,              ONLY : io_push_title,io_push_bar
  USE westcom,              ONLY : dvg,dng,n_pdep_eigen,trev_pdep,n_pdep_maxiter,n_pdep_basis,wstat_calculation,ev,conv,&
                                   & n_pdep_restart_from_itr,n_pdep_read_from_file,n_steps_write_restart,n_pdep_times,&
                                   & trev_pdep_rel,tr2_dfpt,l_is_wstat_converged, &
                                   & ngq,npwq,igq_q,npwqx
  USE pdep_db,              ONLY : pdep_db_write,pdep_db_read
  USE wstat_restart,        ONLY : wstat_restart_write, wstat_restart_clear, wstat_restart_read
  USE mp_world,             ONLY : mpime
  USE mp_global,            ONLY : inter_image_comm
  USE mp,                   ONLY : mp_sum
  USE gvect,                ONLY : gstart, g, ngm
  USE gvecw,                ONLY : gcutw
  USE wstat_tools,          ONLY : diagox,serial_diagox,build_hr,symm_hr_distr,redistribute_vr_distr,&
                                   & update_with_vr_distr,refresh_with_vr_distr 
  USE types_bz_grid,        ONLY : q_grid
  USE types_coulomb,        ONLY : pot3D
  !
  IMPLICIT NONE
  !
  ! ... LOCAL variables
  !
  INTEGER :: nvec, nvecx
    ! dimension of the matrix to be diagonalized
    ! leading dimension of matrix evc, as declared in the calling pgm unit
  INTEGER :: dav_iter, notcnv
    ! integer  number of iterations performed
    ! number of unconverged roots
  INTEGER :: kter, nbase, np, n, m
    ! counter on iterations
    ! dimension of the reduced basis
    ! counter on the reduced basis vectors
    ! do-loop counters
    ! counter on the bands
  INTEGER :: ierr,mloc,mstart,mend
  INTEGER,ALLOCATABLE :: ishift(:)
  REAL(DP), ALLOCATABLE :: ew(:)
  COMPLEX(DP), ALLOCATABLE :: hr_distr(:,:), vr_distr(:,:)
  !
  INTEGER :: il1,il2,ig1,ig2,i
  REAL(DP) :: time_spent(2)
  INTEGER :: sternop_ncalls(2)
  CHARACTER(LEN=8) :: iter_label
  REAL(DP) :: pccg_res_tr2
  INTEGER :: dfpt_dim, diago_dim
  !
  INTEGER :: iq, lastdone_iq
  LOGICAL :: l_restart_q_done
  LOGICAL :: l_print_pdep_read
  REAL(DP) :: q(3)
  !
  REAL(DP), EXTERNAL :: GET_CLOCK
  !
  ! ... INITIALIZATION
  !
  l_is_wstat_converged = .FALSE.
  nvec = n_pdep_eigen
  nvecx = n_pdep_basis
  lastdone_iq = 0
  l_restart_q_done = .FALSE.
  !
  ! ... DISTRIBUTE nvecx
  !
  pert=idistribute()
  CALL pert%init(nvecx,'i','nvecx',.TRUE.)
  !CALL index_distr_init(pert,nvecx,'i','nvecx',.TRUE.) 
  CALL wstat_memory_report() ! Before allocating I report the memory required. 
  !
  ! ... MEMORY ALLOCATION
  !
  IF ( nvec > nvecx / 2 ) CALL errore( 'chidiago', 'nvecx is too small', 1 )
  !
  ALLOCATE( dvg( npwqx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate dvg ', ABS(ierr) )
  !
  ALLOCATE( dng( npwqx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate dng ', ABS(ierr) )
  !
  ALLOCATE( hr_distr( nvecx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate hr_distr ', ABS(ierr) )
  !
  ALLOCATE( vr_distr( nvecx, pert%nlocx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate vr_distr ', ABS(ierr) )
  !
  ALLOCATE( ew( nvecx ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate ew ', ABS(ierr) )
  !
  ALLOCATE( ev( nvec  ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate ev ', ABS(ierr) )
  !
  ALLOCATE( conv( nvec ), STAT=ierr )
  IF( ierr /= 0 ) &
     CALL errore( 'chidiago',' cannot allocate conv ', ABS(ierr) )
  !
  QPOINTS_LOOP: &
  DO iq = 1, q_grid%np
     !
     CALL start_clock( 'chidiago' )
     time_spent(1)=get_clock( 'chidiago' )
     CALL get_clock_called( 'stern' , sternop_ncalls(1) )
     !
     nbase  = nvec
     conv   = .FALSE.
     ev     = 0._DP
     ew     = 0._DP
     dng  = 0._DP
     dvg  = 0._DP
     hr_distr(:,:) = 0._DP
     vr_distr(:,:) = 0._DP
     notcnv  = nvec 
     dav_iter = -2
     !
     ! set local number of G vectors for perturbation at q
     !
     npwq = ngq(iq)
     !
     ! compute Coulomb potential
     !
     CALL pot3D%init('Wave',.TRUE.,'default',iq)
     CALL pot3d%print_divergence()
     !
     IF ( q_grid%np > 1 ) THEN
        !
        IF ( wstat_calculation(1:1) == 'S' .OR. wstat_calculation(2:2) == 'S' ) THEN
           !
           WRITE( stdout, '(/,5x,64a)' ) ('=',i=1,64)
           WRITE( stdout, '(5x,a,i5.5,a,3f10.4,a)')&
           'PDEP calculation at q(',iq,') = (',q_grid%p_cart(:,iq),' )'
           WRITE( stdout, '(5x,64a)' ) ('-',i=1,64)
           !
        ELSEIF ( (wstat_calculation(1:1) == 'R' .OR. wstat_calculation(2:2) == 'R') .AND. l_restart_q_done ) THEN
           !
           WRITE( stdout, '(/,5x,64a)' ) ('=',i=1,64)
           WRITE( stdout, '(5x,a,i5.5,a,3f10.4,a)')&
           'PDEP calculation at q(',iq,') = (',q_grid%p_cart(:,iq),' )'
           WRITE( stdout, '(5x,64a)' ) ('-',i=1,64)
           !
        ENDIF
        !
     ENDIF
     !
     ! KIND OF CALCULATION
     !
     IF( wstat_calculation(1:1) == "R" .OR. wstat_calculation(2:2) == "R" ) THEN 
        !
        IF ( .NOT. l_restart_q_done ) THEN
           !
           CALL wstat_restart_read( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr, lastdone_iq, iq )
           !
           IF ( iq < lastdone_iq ) THEN
              CYCLE QPOINTS_LOOP
           ELSEIF ( iq == lastdone_iq .AND. notcnv == 0 ) THEN
              CYCLE QPOINTS_LOOP
           ENDIF
           !
           l_restart_q_done = .TRUE.
           wstat_calculation = 'S' ! Start from scratch for the next q (after restart has been done)
           !
        ENDIF
        !
     ENDIF
     IF( wstat_calculation(1:1) == "S" .OR. wstat_calculation(2:2) == "S" ) THEN
        !
        ! FROM SCRATCH
        !
        ! ... Eventually read from file
        !
        IF (iq==1) THEN 
           l_print_pdep_read = .TRUE.
        ELSE 
           l_print_pdep_read = .FALSE.
        ENDIF
        IF(n_pdep_read_from_file>0) CALL pdep_db_read( n_pdep_read_from_file, iq, l_print_pdep_read)
        !
        ! ... Eventually randomize
        !
        IF(n_pdep_read_from_file<nvec) CALL do_randomize_q ( dvg, n_pdep_read_from_file+1, nvec, iq)
        !
        ! ... MGS
        !
        CALL do_mgs( dvg, 1, nvec)
        !
        dfpt_dim = nbase
        diago_dim = nbase
        WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
        WRITE(stdout, &
            & "(   5x,'#     Iteration = | ', a8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |  x 1/2')")&
            & 'starting', dfpt_dim, diago_dim
        WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
        !
        ! Apply operator with DFPT
        !
        mloc = 0
        mstart = 1 
        DO il1 = 1, pert%nloc
           ig1 = pert%l2g(il1)
           IF( ig1 < 1 .OR. ig1 > nvec ) CYCLE
           IF( mloc==0 ) mstart = il1
           mloc = mloc + 1
        ENDDO
        !
        pccg_res_tr2 = -1._DP
        !
        CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2, iq ) 
        dav_iter = -1
        CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr, iq)
        !
     ENDIF
     !
     IF( dav_iter == -2 ) CALL errore( 'chidiago','Cannot find the 1st starting loop',1) 
     !
     IF( dav_iter == -1 ) THEN
        !
        ! < EXTRA STEP > 
        !
        dvg = dng
        CALL do_mgs( dvg, 1, nvec)
        !
        dfpt_dim = nbase
        diago_dim = nbase
        WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
        WRITE(stdout, &
            & "(   5x,'#     Iteration = | ', a8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |  x 2/2')")&
            & 'starting', dfpt_dim, diago_dim
        WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
        !
        ! Apply operator with DFPT
        !
        mloc = 0
        mstart = 1 
        DO il1 = 1, pert%nloc
           ig1 = pert%l2g(il1)
           IF( ig1 < 1 .OR. ig1 > nvec ) CYCLE
           IF( mloc==0 ) mstart = il1
           mloc = mloc + 1
        ENDDO
        !
        pccg_res_tr2 = MIN(0.01_DP,1000000._DP*tr2_dfpt)
        !
        CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2, iq ) 
        ! 
        ! </ EXTRA STEP >
        !
        ! hr = <dvg|dng>
        !
        CALL build_hr( dvg, dng, mstart, mstart+mloc-1, hr_distr, 1, nvec ) 
        !
        ! ... diagonalize the reduced hamiltonian
        !
        CALL diagox( nbase, nvec, hr_distr, nvecx, ew, vr_distr )
        time_spent(2)=get_clock( 'chidiago' )
        CALL get_clock_called( 'stern' , sternop_ncalls(2) )
        ev(1:nvec) = ew(1:nvec)
        !
        ! Write the eigenvalues & time spent
        !
        CALL output_ev_and_time_q( nvec,ev,conv,time_spent,sternop_ncalls,pccg_res_tr2,dfpt_dim,diago_dim,dav_iter,notcnv,iq )
        dav_iter = 0
        CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr, iq )
        !
     ENDIF
     !
     ! --------------------
     !
     ! ... iterate
     !
     ! --------------------
     !
     iterate: DO kter = 1, n_pdep_maxiter
        !
        time_spent(1) = get_clock( 'chidiago' )
        CALL get_clock_called( 'stern' , sternop_ncalls(1) )
        !
        dav_iter = dav_iter + 1
        !
        dfpt_dim = notcnv
        diago_dim = nbase+notcnv
        WRITE(stdout, "( /,5x,'                  *----------*              *----------*               *----------*') ")
        WRITE(stdout, "(   5x,'#     Iteration = | ', i8,' |','   ','DFPT_dim = | ', i8,' |', '   ','Diago_dim = | ', i8,' |')") &
         &dav_iter, dfpt_dim, diago_dim
        WRITE(stdout, "(   5x,'                  *----------*              *----------*               *----------*') ")
        !
        ALLOCATE( ishift( nvecx ), STAT=ierr )
        IF( ierr /= 0 ) CALL errore( 'chidiago',' cannot allocate ishift ', ABS(ierr) )
        ishift=0
        np = 0
        !
        DO n = 1, nvec
           !
           IF ( .NOT. conv(n) ) THEN
              !
              ! ... this root not yet converged ... 
              !
              np = np + 1
              !
              ! ... reorder eigenvectors so that coefficients for unconverged
              ! ... roots come first. This allows to use quick matrix-matrix 
              ! ... multiplications to set a new basis vector (see below)
              !
              !IF ( np /= n ) vr(:,np) = vr(:,n)
              ishift(nbase+np) = n
              !
              ew(nbase+np) = ev(n)
              !   
           END IF
           !
        END DO
        !
        ! ... expand the basis set with new basis vectors ( H - e*S )|psi> ...
        !
        CALL redistribute_vr_distr( notcnv, nbase, nvecx, vr_distr, ishift )
        DEALLOCATE(ishift)
        CALL update_with_vr_distr( dvg, dng, notcnv, nbase, nvecx, vr_distr, ew )
        !
        ! ... MGS
        !
        CALL do_mgs(dvg,nbase+1,nbase+notcnv)
        !
        ! apply the response function to new vectors
        !
        ! determine image that actually compute dng first
        !
        mloc = 0 
        mstart = 1
        DO il1 = 1, pert%nloc
           ig1 = pert%l2g(il1)
           IF( ig1 < nbase+1 .OR. ig1 > nbase+notcnv ) CYCLE
           IF( mloc==0 ) mstart = il1
           mloc = mloc + 1
        ENDDO
        !
        ! Apply operator with DFPT
        !
        pccg_res_tr2 = tr2_dfpt
        !
        CALL apply_operator ( mloc, dvg(1,mstart), dng(1,mstart), pccg_res_tr2, iq ) 
        !
        ! ... update the reduced hamiltonian
        !
        !
        ! hr = <dvg|dng>
        !
        CALL build_hr( dvg, dng, mstart, mstart+mloc-1, hr_distr, nbase+1, nbase+notcnv ) 
        !
        nbase = nbase + notcnv
        !
        CALL symm_hr_distr(hr_distr,nbase,nvecx)
        !
        ! ... diagonalize the reduced hamiltonian
        !
        CALL diagox( nbase, nvec, hr_distr, nvecx, ew, vr_distr )
        time_spent(2)=get_clock( 'chidiago' )
        CALL get_clock_called( 'stern' , sternop_ncalls(2) )
        !
        ! ... test for convergence
        !
        conv(1:nvec) = ( ( ABS( (ew(1:nvec) - ev(1:nvec))/ev(1:nvec) ) < trev_pdep_rel ) &
                    .AND. ( ABS( ew(1:nvec) - ev(1:nvec) ) < trev_pdep ) )
        !conv(1:nvec) = ( ( ABS( ew(1:nvec) - ev(1:nvec) ) < trev_pdep ) )
        !
        notcnv = COUNT( .NOT. conv(:) )
        !
        ev(1:nvec) = ew(1:nvec)
        !
        ! Write the eigenvalues & time spent
        !
        CALL output_ev_and_time_q(nvec,ev,conv,time_spent,sternop_ncalls,pccg_res_tr2,dfpt_dim,diago_dim,dav_iter,notcnv,iq)
        !
        ! ... if overall convergence has been achieved, or the dimension of
        ! ... the reduced basis set is becoming too large, or in any case if
        ! ... we are at the last iteration refresh the basis set. i.e. replace
        ! ... the first nvec elements with the current estimate of the
        ! ... eigenvectors;  set the basis dimension to nvec.
        !
        IF ( notcnv == 0 .OR. nbase+notcnv > nvecx .OR. kter == n_pdep_maxiter ) THEN
           !
           CALL start_clock( 'chidiago:last' )
           !
           IF ( notcnv == 0 ) THEN
              !
              ! ... all roots converged: return
              !
              CALL stop_clock( 'chidiago:last' )
              !
              CALL refresh_with_vr_distr( dvg, nvec, nbase, nvecx, vr_distr )
              !
              CALL pdep_db_write( iq )
              CALL wstat_restart_clear()
              !CALL output_a_report(-1)
              !
              WRITE(iter_label,'(i8)') kter
              CALL io_push_title("Convergence achieved !!! in "//TRIM(iter_label)//" steps") 
              l_is_wstat_converged = .TRUE.
              !
              EXIT iterate
              !
           ELSE IF ( kter == n_pdep_maxiter ) THEN
              !
              ! ... last iteration, some roots not converged: return
              !
              WRITE( stdout, '(5X,"WARNING: ",I5, &
                   &   " eigenvalues not converged in chidiago")' ) notcnv
              !
              CALL stop_clock( 'chidiago:last' )
              !
              EXIT iterate
              !
           END IF
           !
           ! ... refresh psi, H*psi and S*psi
           !
           WRITE(stdout,'(/,7x,"Refresh the basis set")')
           !
           CALL refresh_with_vr_distr( dvg, nvec, nbase, nvecx, vr_distr )
           CALL refresh_with_vr_distr( dng, nvec, nbase, nvecx, vr_distr )
           !
           ! ... refresh the reduced hamiltonian
           !
           nbase = nvec
           !
           hr_distr = 0._DP
           vr_distr = 0._DP
           !
           DO il1 = 1, pert%nloc
              ig1 = pert%l2g(il1)
              IF ( ig1 < 1 .OR. ig1 > nbase ) CYCLE
              hr_distr(ig1,il1) = ev(ig1)
              vr_distr(ig1,il1) = 1._DP
           ENDDO
           !
           CALL stop_clock( 'chidiago:last' )
           !
        END IF
        !
        CALL wstat_restart_write( dav_iter, notcnv, nbase, ew, hr_distr, vr_distr, iq)
        !!CALL output_a_report(dav_iter)
        !
     END DO iterate
  !
  CALL stop_clock( 'chidiago' )
  !
  ENDDO QPOINTS_LOOP ! iq
  !
  DEALLOCATE( conv )
  DEALLOCATE( ew )
  DEALLOCATE( ev )
  DEALLOCATE( hr_distr )
  DEALLOCATE( vr_distr )
  !
  !
  DEALLOCATE( dng )
  DEALLOCATE( dvg )
  !
  RETURN
  !
END SUBROUTINE
!
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
SUBROUTINE do_mgs(amat,m_global_start,m_global_end) 
  !
  ! MGS of the vectors beloging to the interval [ m_global_start, m_global_end ]
  !    also with respect to the vectors belonging to the interval [ 1, m_global_start -1 ]
  !
  USE kinds,                  ONLY : DP
  USE io_global,              ONLY : stdout
  USE mp_global,              ONLY : intra_bgrp_comm,inter_image_comm,my_image_id,nimage,world_comm 
  USE gvect,                  ONLY : gstart
  USE mp,                     ONLY : mp_sum,mp_barrier,mp_bcast
  USE westcom,                ONLY : npwq,npwqx
  USE control_flags,          ONLY : gamma_only
  USE io_push,                ONLY : io_push_title 
  USE distribution_center,    ONLY : pert
  !
  IMPLICIT NONE
  !
  ! I/O
  !
  INTEGER, INTENT(IN) :: m_global_start,m_global_end
  COMPLEX(DP) :: amat(npwqx,pert%nlocx)
  !
  ! Workspace 
  !
  INTEGER :: ig, ip, j, ncol
  INTEGER :: k_global, k_local, j_local, k_id
  REAL(DP) :: anorm
  REAL(DP),ALLOCATABLE :: braket(:)
  REAL(DP) :: time_spent(2)
  COMPLEX(DP),ALLOCATABLE :: vec(:),zbraket(:)
  LOGICAL :: unfinished
  COMPLEX(DP) :: za
  INTEGER :: m_local_start,m_local_end
  !
  REAL(DP),EXTERNAL :: DDOT
  COMPLEX(DP),EXTERNAL :: ZDOTC
  !
  CALL mp_barrier(world_comm)
  !
  CALL start_clock ('paramgs')
  !
  ALLOCATE( vec(npwqx), zbraket(pert%nloc), braket(pert%nloc) )
  !
  ! 1) Run some checks
  !
  IF( m_global_start < 1 .OR. m_global_start > m_global_end .OR. m_global_end > pert%nglob ) &
     & CALL errore( 'mgs', 'do_mgs problem', 1 )
  !
  ! 2) Localize m_global_start
  !
  m_local_start = 1 
  DO ip = 1, pert%nloc
     ig = pert%l2g(ip)
     IF( ig < m_global_start ) CYCLE
     m_local_start = ip 
     EXIT
  ENDDO
  !
  ! 3) Localize m_global_end
  !
  m_local_end = pert%nloc
  DO ip = pert%nloc, 1, -1
     ig = pert%l2g(ip)
     IF( ig > m_global_end ) CYCLE
     m_local_end = ip
     EXIT
  ENDDO
  !
  j_local=1
  unfinished=.true.
  !
  !DO k_global=m_global_start,m_global_end
  DO k_global=1,m_global_end
     !
     CALL pert%g2l(k_global,k_local,k_id)
     !CALL distr_g2l(k_global,k_local,k_id,nimage)
     !
     IF(my_image_id==k_id) THEN
        !
        ! 4) Eventually, normalize the current vector
        !
        IF( k_global >= m_global_start ) THEN
           !
           ! anorm = < k_l | k_l >
           !
           IF(gamma_only) THEN
              anorm = 2.0_DP * DDOT(2*npwq,amat(1,k_local),1,amat(1,k_local),1)
              IF(gstart==2) anorm = anorm - REAL(amat(1,k_local),KIND=DP) * REAL(amat(1,k_local),KIND=DP)
           ELSE
              anorm = DDOT(2*npwq,amat(1,k_local),1,amat(1,k_local),1)
           ENDIF
           !
           CALL mp_sum(anorm,intra_bgrp_comm)
           !
           ! normalize | k_l >
           !
           za = CMPLX( 1._DP/SQRT(anorm), 0._DP,KIND=DP)
           CALL ZSCAL(npwq,za,amat(1,k_local),1)
           !
        ENDIF
        !
        ! 5) Copy the current vector into V
        !
        CALL ZCOPY(npwqx,amat(1,k_local),1,vec(1),1)
        !
        j_local=MAX(k_local+1,m_local_start)
        !
        !IF(j_local>pert%nloc) unfinished=.false.
        IF(j_local>m_local_end) unfinished=.false.
        !
     ENDIF
     !
     ! BCAST | vec >
     !
     CALL mp_bcast(vec,k_id,inter_image_comm)
     !
     ! Update when needed
     !
     IF(unfinished) THEN
        !
        ! IN the range ip=j_local:pert%nloc    = >    | ip > = | ip > - | vec > * < vec | ip >
        !
        IF(gamma_only) THEN
           DO ip = j_local,m_local_end !pert%nloc
              braket(ip) = 2._DP * DDOT(2*npwq,vec(1),1,amat(1,ip),1)
           ENDDO
           !IF (gstart==2) FORALL( ip=j_local:pert%nloc ) braket(ip) = braket(ip) - REAL(vec(1),KIND=DP)*REAL(amat(1,ip),KIND=DP) 
           IF (gstart==2) FORALL( ip=j_local:m_local_end ) braket(ip) = braket(ip) - REAL(vec(1),KIND=DP)*REAL(amat(1,ip),KIND=DP) 
           !CALL mp_sum(braket(j_local:pert%nloc),intra_bgrp_comm)
           CALL mp_sum(braket(j_local:m_local_end),intra_bgrp_comm)
           !FORALL(ip=j_local:pert%nloc) zbraket(ip) = CMPLX( braket(ip), 0._DP, KIND=DP)
           FORALL(ip=j_local:m_local_end) zbraket(ip) = CMPLX( braket(ip), 0._DP, KIND=DP)
        ELSE
           DO ip = j_local,m_local_end !pert%nloc
              zbraket(ip) = ZDOTC(npwq,vec(1),1,amat(1,ip),1)
           ENDDO
           !CALL mp_sum(zbraket(j_local:pert%nloc),intra_bgrp_comm)
           CALL mp_sum(zbraket(j_local:m_local_end),intra_bgrp_comm)
        ENDIF
        !
        ncol=m_local_end-j_local+1
        !ncol=m_global_end-j_local+1
        CALL ZGERU(npwqx,ncol,(-1._DP,0._DP),vec(1),1,zbraket(j_local),1,amat(1,j_local),npwqx)
        !
     ENDIF
     !
  ENDDO
  !
  DEALLOCATE( vec,zbraket,braket )
  !
  CALL mp_barrier(world_comm)
  !
  CALL stop_clock ('paramgs')
  !
END SUBROUTINE
!
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
SUBROUTINE do_randomize ( amat, mglobalstart, mglobalend  ) 
  !
  ! Randomize in dvg the vectors belonging to [ mglobalstart, mglobalend ]
  !
  USE kinds,                ONLY : DP
  USE random_numbers,       ONLY : randy
  USE gvect,                ONLY : g,gstart,ngm_g,ig_l2g
  USE westcom,              ONLY : npwq,dvg,npwqx
  USE constants,            ONLY : tpi
  USE mp,                   ONLY : mp_barrier
  USE mp_global,            ONLY : world_comm
  USE distribution_center,  ONLY : pert
  !
  IMPLICIT NONE
  !
  ! I/O
  !
  INTEGER,INTENT(IN) :: mglobalstart, mglobalend
  COMPLEX(DP) :: amat(npwqx,pert%nlocx)
  !
  ! Workspace
  !
  REAL(DP),ALLOCATABLE :: random_num_debug(:,:)
  INTEGER :: il1,ig1,ig
  REAL(DP) :: aux_real
  REAL(DP) :: rr, arg
  !
  CALL mp_barrier(world_comm)
  !
  CALL start_clock ('randomize')
  !
  ! Random numbers are generated according to G-global
  !
  ALLOCATE(random_num_debug(2,ngm_g))
  !
  DO il1=1,pert%nloc
     !
     ig1=pert%l2g(il1)
     IF( ig1 < mglobalstart .OR. ig1 > mglobalend ) CYCLE
     !
     ! Initialize the sequence
     !
     aux_real=randy(ig1)
     !
     DO ig=1,ngm_g
        random_num_debug(1:2,ig) = (/ randy(), randy() /)
     ENDDO
     !
     amat(:,il1) = 0._DP
!$OMP PARALLEL private(ig,rr,arg)
!$OMP DO
     DO ig=gstart,npwq
        rr = random_num_debug(1,ig_l2g(ig))
        arg = tpi * random_num_debug(2,ig_l2g(ig))
        amat(ig,il1) = CMPLX( rr*COS( arg ), rr*SIN( arg ), KIND=DP) / &
                      ( g(1,ig)*g(1,ig) + &
                        g(2,ig)*g(2,ig) + &
                        g(3,ig)*g(3,ig) + 1.0_DP )
     ENDDO
!$OMP ENDDO
!$OMP END PARALLEL
     !
  ENDDO
  !
  DEALLOCATE(random_num_debug)
  !
  CALL stop_clock ('randomize')
  !
END SUBROUTINE
!
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
SUBROUTINE do_randomize_q (amat, mglobalstart, mglobalend, iq) 
  !
  ! Randomize in dvg the vectors belonging to [ mglobalstart, mglobalend ]
  !
  USE kinds,                ONLY : DP
  USE random_numbers,       ONLY : randy
  USE gvect,                ONLY : g,gstart,ngm_g,ig_l2g
  USE westcom,              ONLY : dvg,npwqx,ngq,igq_q
  USE constants,            ONLY : tpi,eps8
  USE cell_base,            ONLY : tpiba2
  USE mp,                   ONLY : mp_barrier
  USE mp_global,            ONLY : world_comm
  USE distribution_center,  ONLY : pert
  USE types_bz_grid,        ONLY : q_grid
  !
  IMPLICIT NONE
  !
  ! I/O
  !
  INTEGER,INTENT(IN) :: mglobalstart, mglobalend
  COMPLEX(DP) :: amat(npwqx,pert%nlocx)
  INTEGER,INTENT(IN) :: iq
  !
  ! Workspace
  !
  REAL(DP),ALLOCATABLE :: random_num_debug(:,:)
  INTEGER :: il1,ig1,ig
  REAL(DP) :: aux_real
  REAL(DP) :: rr, arg, qg(3), qgnorm2
  !
  CALL mp_barrier(world_comm)
  !
  CALL start_clock ('randomize')
  !
  ! Random numbers are generated according to G-global
  !
  ALLOCATE(random_num_debug(2,ngm_g))
  !
  DO il1=1,pert%nloc
     !
     ig1=pert%l2g(il1)
     IF( ig1 < mglobalstart .OR. ig1 > mglobalend ) CYCLE
     !
     ! Initialize the sequence
     !
     aux_real=randy(ig1)
     !
     DO ig=1,ngm_g
        random_num_debug(1:2,ig) = (/ randy(), randy() /)
     ENDDO
     !
     amat(:,il1) = 0._DP
!$OMP PARALLEL private(ig,rr,arg)
!$OMP DO
     DO ig=1,ngq(iq)
        qg(:) = q_grid%p_cart(:,iq) + g(:,igq_q(ig,iq))
        qgnorm2 = SUM( qg(:)**2 ) * tpiba2
        IF ( qgnorm2 < eps8 ) CYCLE
        rr = random_num_debug(1,ig_l2g(igq_q(ig,iq)))
        arg = tpi * random_num_debug(2,ig_l2g(igq_q(ig,iq)))
        amat(ig,il1) = CMPLX( rr*COS( arg ), rr*SIN( arg ), KIND=DP) / ( qgnorm2 + 1.0_DP ) 
     ENDDO
!$OMP ENDDO
!$OMP END PARALLEL
     !
  ENDDO
  !
  DEALLOCATE(random_num_debug)
  !
  CALL stop_clock ('randomize')
  !
END SUBROUTINE
!
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
!SUBROUTINE output_a_report(iteration)
!   !
!   USE json_module,  ONLY : json_file
!   USE kinds,        ONLY : DP
!   USE westcom,      ONLY : n_pdep_eigen,ev,conv,wstat_output_dir,logfile
!   USE west_io ,     ONLY : serial_table_output
!   USE mp_world,     ONLY : mpime,root
!   !
!   IMPLICIT NONE
!   !
!   TYPE(json_file) :: json
!   INTEGER,INTENT(IN) :: iteration
!   CHARACTER(LEN=9) :: pref
!   INTEGER :: ip, ierr, iunit
!   !REAL(DP) :: out_tab(n_pdep_eigen,3)
!   !
!   INTEGER,ALLOCATABLE :: converged(:)
!   !
!   ALLOCATE( converged(n_pdep_eigen) )
!   !
!   converged = 0
!   DO ip=1,n_pdep_eigen
!      !out_tab(ip,1) = REAL(ip,DP)
!      !ipert(ip) = ip 
!      !out_tab(ip,2) = ev(ip)
!      !out_tab(ip,3) = 0._DP
!      !IF(conv(ip)) out_tab(ip,3) = 1._DP
!      IF(conv(ip)) converged(ip) = 1
!   ENDDO
!   IF(iteration>=0) THEN 
!      WRITE(pref,"('itr_',i5.5)") iteration
!   ELSE
!      pref='converged'
!   ENDIF
!   !CALL serial_table_output(mpime==root,4000,'wstat.'//TRIM(ADJUSTL(pref)),out_tab,n_pdep_eigen,3,(/'   iprt','eigenv.','  conv.'/))
!   !
!   IF( mpime == root ) THEN 
!      !
!      CALL json%initialize()
!      !
!      CALL json%load_file(filename=TRIM(logfile))
!      !
!      CALL json%add('output.davitr'//TRIM(pref)//.'egvl',  ev        ( 1:n_pdep_eigen ) )
!      CALL json%add('output.davitr'//TRIM(pref)//.'conv',  converged ( 1:n_pdep_eigen ) )
!      !
!      !OPEN(UNIT=4000,FILE=TRIM(ADJUSTL(wstat_output_dir))//"/o-wstat."//TRIM(ADJUSTL(pref))//".json",IOSTAT=ierr) 
!      !CALL json%print_file( 4000 )
!      !CLOSE( 4000, IOSTAT=ierr )
!      !
!      OPEN( NEWUNIT=iunit,FILE=TRIM(logfile) )
!      CALL json%print_file( iunit )
!      CLOSE( iunit )
!      !
!      CALL json%destroy()
!      !
!   ENDIF 
!   !
!   !DEALLOCATE( iprt ) 
!   DEALLOCATE( converged ) 
!   !
!END SUBROUTINE
!
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
SUBROUTINE output_ev_and_time(nvec,ev_,conv_,time,sternop,tr2,dfpt_dim,diago_dim,dav_iter,notcnv)
   !
   USE json_module,          ONLY : json_file
   USE kinds,                ONLY : DP
   USE io_global,            ONLY : stdout
   USE io_push,              ONLY : io_push_title,io_push_bar
   USE mp_world,             ONLY : mpime, root
   USE westcom,              ONLY : logfile
   !
   IMPLICIT NONE
   !
   TYPE(json_file) :: json
   INTEGER,INTENT(IN) :: nvec
   REAL(DP),INTENT(IN) :: ev_(nvec)
   LOGICAL,INTENT(IN) :: conv_(nvec)
   REAL(DP),INTENT(IN) :: time(2)
   INTEGER,INTENT(IN) :: sternop(2)
   REAL(DP),INTENT(IN) :: tr2
   INTEGER,INTENT(IN) :: dav_iter, notcnv, dfpt_dim, diago_dim
   !
   INTEGER :: i,j, ip
   CHARACTER(20),EXTERNAL :: human_readable_time
   CHARACTER(LEN=6) :: cdav
   INTEGER :: ndav,iunit
   LOGICAL :: found
   !
   WRITE(stdout,'(7X,a)') ' '
   DO i = 1, INT( nvec / 9 )
      WRITE(stdout,'(6X, 9(f9.5,1x))') (ev_(j), j=9*(i-1)+1,9*i)
   ENDDO
   IF( MOD(nvec,9) > 0 ) WRITE(stdout,'(6X, 9(f9.5,1x))') (ev_(j), j=9*INT(nvec/9)+1,nvec)
   WRITE(stdout,'(7X,a)') ' '
   CALL io_push_bar()
   WRITE(stdout, "(5x,'Tot. elapsed time ',a,',  time spent in last iteration ',a) ") &
   TRIM(human_readable_time(time(2))), TRIM(human_readable_time(time(2)-time(1)))
   CALL io_push_bar()
   !
   IF( mpime == root ) THEN 
      !
      CALL json%initialize()
      !
      CALL json%load_file(filename=TRIM(logfile))
      !
      CALL json%get('exec.ndav', ndav, found )
      !
      IF( found ) THEN 
         ndav = ndav+1
      ELSE 
         ndav = 1
      ENDIF
      !
      WRITE(cdav,'(i6)') ndav
      !
      CALL json%update('exec.ndav', ndav, found )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').dav_iter', dav_iter )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').ev',  ev_        ( 1:nvec ) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').conv', conv_ ( 1:nvec ) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').notcnv', notcnv )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').time_elap:sec', time(2) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').time_elap:hum', TRIM(human_readable_time(time(2))) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').time_iter:sec', (time(2)-time(1)))
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').time_iter:hum', TRIM(human_readable_time(time(2)-time(1))) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').sternop_ncalls', sternop(2)-sternop(1) )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').dfpt_tr2', tr2 )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').dfpt_dim', dfpt_dim )
      CALL json%add('exec.davitr('//TRIM(ADJUSTL(cdav))//').diago_dim', diago_dim )
      !
      OPEN( NEWUNIT=iunit,FILE=TRIM(logfile) )
      CALL json%print_file( iunit )
      CLOSE( iunit )
      !
      CALL json%destroy()
      !
   ENDIF 
   !
END SUBROUTINE

! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
! %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!
SUBROUTINE output_ev_and_time_q(nvec,ev_,conv_,time,sternop,tr2,dfpt_dim,diago_dim,dav_iter,notcnv,iq)
   !
   USE json_module,          ONLY : json_file
   USE kinds,                ONLY : DP
   USE io_global,            ONLY : stdout
   USE io_push,              ONLY : io_push_title,io_push_bar
   USE mp_world,             ONLY : mpime, root
   USE westcom,              ONLY : logfile
   USE types_bz_grid,        ONLY : q_grid
   !
   IMPLICIT NONE
   !
   TYPE(json_file) :: json
   INTEGER,INTENT(IN) :: nvec
   REAL(DP),INTENT(IN) :: ev_(nvec)
   LOGICAL,INTENT(IN) :: conv_(nvec)
   REAL(DP),INTENT(IN) :: time(2)
   INTEGER,INTENT(IN) :: sternop(2)
   REAL(DP),INTENT(IN) :: tr2
   INTEGER,INTENT(IN) :: dav_iter, notcnv, dfpt_dim, diago_dim
   INTEGER,INTENT(IN) :: iq
   !
   INTEGER :: i,j, ip
   CHARACTER(20),EXTERNAL :: human_readable_time
   CHARACTER(LEN=6) :: cdav
   CHARACTER(LEN=5) :: cq
   INTEGER :: ndav(q_grid%np),iunit
   LOGICAL :: found
   !
   WRITE(stdout,'(7X,a)') ' '
   DO i = 1, INT( nvec / 9 )
      WRITE(stdout,'(6X, 9(f9.5,1x))') (ev_(j), j=9*(i-1)+1,9*i)
   ENDDO
   IF( MOD(nvec,9) > 0 ) WRITE(stdout,'(6X, 9(f9.5,1x))') (ev_(j), j=9*INT(nvec/9)+1,nvec)
   WRITE(stdout,'(7X,a)') ' '
   CALL io_push_bar()
   WRITE(stdout, "(5x,'Tot. elapsed time ',a,',  time spent in last iteration ',a) ") &
   TRIM(human_readable_time(time(2))), TRIM(human_readable_time(time(2)-time(1)))
   CALL io_push_bar()
   !
   IF( mpime == root ) THEN 
      !
      CALL json%initialize()
      !
      CALL json%load_file(filename=TRIM(logfile))
      !
      WRITE(cq,'(i5)') iq
      !
      CALL json%get('exec.ndav.Q'//TRIM((ADJUSTL(cq))), ndav(iq), found )
      !
      IF( found ) THEN 
         ndav(iq) = ndav(iq)+1
      ELSE 
         ndav(iq) = 1
      ENDIF
      !
      WRITE(cdav,'(i6)') ndav(iq)
      !
      CALL json%update('exec.ndav.Q'//TRIM(ADJUSTL(cq)), ndav(iq), found )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').dav_iter', dav_iter )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').ev',  ev_        ( 1:nvec ) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').conv', conv_ ( 1:nvec ) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').notcnv', notcnv )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').time_elap:sec', time(2) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').time_elap:hum',&
        & TRIM(human_readable_time(time(2))) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').time_iter:sec',&
        & (time(2)-time(1)))
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').time_iter:hum',&
        & TRIM(human_readable_time(time(2)-time(1))) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').sternop_ncalls',&
        & sternop(2)-sternop(1) )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').dfpt_tr2', tr2 )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').dfpt_dim', dfpt_dim )
      CALL json%add('exec.davitr.Q'//TRIM(ADJUSTL(cq))//'('//TRIM(ADJUSTL(cdav))//').diago_dim', diago_dim )
      !
      OPEN( NEWUNIT=iunit,FILE=TRIM(logfile) )
      CALL json%print_file( iunit )
      CLOSE( iunit )
      !
      CALL json%destroy()
      !
   ENDIF 
   !
END SUBROUTINE
