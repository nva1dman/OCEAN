! Copyright (C) 2018 - 2019 OCEAN collaboration
!
! This file is part of the OCEAN project and distributed under the terms 
! of the University of Illinois/NCSA Open Source License. See the file 
! `License' in the root directory of the present distribution.
!
!
! John Vinson
module ocean_qe62_files
  use ai_kinds, only : DP
#ifdef MPI_F08
  use mpi_f08, only : MPI_COMM, MPI_REQUEST
#endif


  implicit none
  private
  save


  logical :: is_init = .false.
  logical :: is_gamma
  logical :: is_shift  ! Is there actually a difference between val and con?
  logical :: is_split  ! Are val and con in different dft runs?
  logical, parameter :: GammaFullStorage = .false.
  character( len=128 ) :: prefix
  character( len=128 ) :: prefixSplit

  integer :: bands(2)
  integer :: brange(4)
  integer :: kpts(3)
  integer :: nspin 
  integer :: nfiles

  real(DP), allocatable :: internal_con_energies( :, :, : )
  real(DP), allocatable :: internal_val_energies( :, :, : )


#ifdef MPI_F08
  type( MPI_COMM ) :: inter_comm
  type( MPI_COMM ) :: pool_comm
#else
  integer :: inter_comm
  integer :: pool_comm
#endif

  integer :: inter_myid
  integer :: inter_nproc
  integer, parameter :: inter_root = 0

  integer :: npool
  integer :: mypool
  integer :: pool_myid
  integer :: pool_nproc
  integer, parameter :: pool_root = 0
  
  integer :: pool_nbands
  integer :: pool_val_nbands
  integer :: pool_con_nbands

  public :: qe62_read_init, qe62_read_at_kpt, qe62_clean, qe62_get_ngvecs_at_kpt, &
            qe62_read_energies_single, qe62_get_ngvecs_at_kpt_split, qe62_read_at_kpt_split
  public :: qe62_read_energies_split
  public :: qe62_kpts_and_spins, qe62_return_my_bands, qe62_return_my_val_bands, qe62_return_my_con_bands, &
            qe62_is_my_kpt 
  public :: qe62_nprocPerPool, qe62_getPoolIndex, qe62_returnGlobalID
  public :: qe62_getAllBandsForPoolID, qe62_getValenceBandsForPoolID, qe62_getConductionBandsForPoolID
  public :: qe62_npool, qe62_universal2KptAndSpin, qe62_poolID, qe62_poolComm
  public :: qe62_read_gvecs_at_kpt

  contains

  pure function qe62_poolComm()
#ifdef MPI_F08
    type( MPI_COMM ) :: qe62_poolComm
#else
    integer :: qe62_poolComm
#endif

    qe62_poolComm = pool_comm
  end function qe62_poolComm

  pure function qe62_npool() result( npool_ )
    integer :: npool_
    npool_ = npool
  end function qe62_npool

  pure function qe62_nprocPerPool() result( nproc )
    integer :: nproc
    
    nproc = pool_nproc
  end function qe62_nprocPerPool

  pure function qe62_poolID() result( pid )
    integer :: pid
    
    pid = pool_myid
  end function qe62_poolID

  pure function qe62_getPoolIndex( ispin, ikpt ) result( poolIndex )
    integer, intent( in ) :: ispin, ikpt
    integer :: poolIndex
    integer :: kptCounter
    !
    kptCounter = ikpt + ( ispin - 1 ) * product(kpts(:))
    poolIndex = mod( kptCounter, npool )
  end function qe62_getPoolIndex

  subroutine qe62_universal2KptAndSpin( uni, ikpt, ispin )
    integer, intent( in ) :: uni
    integer, intent( out ) :: ispin, ikpt
    !
    integer :: i, ierr
    logical :: is_kpt

    i = 0
    do ispin = 1, nspin
      do ikpt = 1, product(kpts(:))
        call qe62_is_my_kpt( ikpt, ispin, is_kpt, ierr )
        if( is_kpt ) i = i +1
        if( uni .eq. i ) return
      enddo
    enddo

    ikpt = 0
    ispin = 0
  end subroutine qe62_universal2KptAndSpin

  pure function qe62_getAllBandsForPoolID( poolID ) result(nbands)
    integer, intent( in ) :: poolID
    integer :: nbands
    integer :: bands_remain, i

    nbands = 0
    bands_remain = bands(2)-bands(1)+1

    if( pool_nproc .gt. bands_remain ) then
      if( poolID .lt. bands_remain ) nbands = 1
      return
    endif

    do i = 0, poolID
      nbands = bands_remain / ( pool_nproc - i )
      bands_remain = bands_remain - nbands
    enddo

  end function qe62_getAllBandsForPoolID

  pure function qe62_getValenceBandsForPoolID( poolID ) result(nbands)
    integer, intent( in ) :: poolID
    integer :: nbands
    integer :: bands_remain, i

!    bands_remain = brange(4)-brange(3)+brange(2)-brange(1)+2
    bands_remain = brange(2) - brange(1) + 1
    nbands = 0

    if( pool_nproc .gt. bands_remain ) then
      if( poolID .lt. bands_remain ) nbands = 1
      return
    endif

    do i = 0, poolID
      nbands = bands_remain / ( pool_nproc - i )
      bands_remain = bands_remain - nbands
    enddo

  end function qe62_getValenceBandsForPoolID

  pure function qe62_getConductionBandsForPoolID( poolID ) result(nbands)
    integer, intent( in ) :: poolID
    integer :: nbands
    integer :: bands_remain, i
    
    nbands = 0
!    bands_remain = brange(4)-brange(3)+brange(2)-brange(1)+2
    bands_remain = brange(4) - brange(3) + 1

    if( pool_nproc .gt. bands_remain ) then
      if( poolID .lt. bands_remain ) nbands = 1
      return
    endif
  
    do i = 0, poolID
      nbands = bands_remain / ( pool_nproc - i )
      bands_remain = bands_remain - nbands
    enddo

  end function qe62_getConductionBandsForPoolID

  pure function qe62_returnGlobalID( poolIndex, poolID ) result( globalID )
    integer, intent( in ) :: poolIndex, poolID
    integer :: globalID

    globalID = poolIndex * pool_nproc + poolID
  end function qe62_returnGlobalID

  subroutine qe62_is_my_kpt( ikpt, ispin, is_kpt, ierr )
    integer, intent( in ) :: ikpt, ispin
    logical, intent( out ) :: is_kpt
    integer, intent( inout ) :: ierr
    !
    if( .not. is_init ) then
      ierr = 222
      return
    endif
    if( ispin .lt. 1 .or. ispin .gt. nspin ) then
      ierr = 322 
      return
    endif
    if( ikpt .lt. 1 .or. ikpt .gt. product(kpts(:)) ) then
      ierr = 422
      return
    endif

!    if( mod( ikpt + (ispin-1)*product(kpts(:)), npool ) .eq. mypool ) then
    if( qe62_getPoolIndex( ispin, ikpt ) .eq. mypool ) then
      is_kpt = .true.
    else
      is_kpt = .false.
    endif

  end subroutine qe62_is_my_kpt

  subroutine qe62_return_my_bands( nbands, ierr )
    integer, intent( out ) :: nbands
    integer, intent( inout ) :: ierr
    
    if( .not. is_init ) ierr = 1
    nbands = pool_nbands
  end subroutine qe62_return_my_bands

  subroutine qe62_return_my_val_bands( nbands, ierr )
    integer, intent( out ) :: nbands
    integer, intent( inout ) :: ierr

    if( .not. is_init ) ierr = 1
    nbands = pool_val_nbands
  end subroutine qe62_return_my_val_bands

  subroutine qe62_return_my_con_bands( nbands, ierr )
    integer, intent( out ) :: nbands
    integer, intent( inout ) :: ierr

    if( .not. is_init ) ierr = 1
    nbands = pool_con_nbands
  end subroutine qe62_return_my_con_bands

  integer function qe62_kpts_and_spins()
    qe62_kpts_and_spins = product(kpts(:)) * nspin / npool
    return
  end function qe62_kpts_and_spins

  subroutine qe62_read_energies_split( myid, root, valEnergies, conEnergies, ierr )
#ifdef MPI
    use ocean_mpi, only : MPI_DOUBLE_PRECISION
#endif
    integer, intent( in ) :: myid, root
    real( DP ), intent( out ), dimension( :, :, : ) :: valEnergies, conEnergies
    integer, intent( inout ) :: ierr

    integer :: nb, nk

    if( is_init .eqv. .false. ) then
      write(6,*) 'qe62_read_energies_single called but was not initialized'
      ierr = 4
      return
    endif

    if( size( valEnergies, 1 ) .lt. ( brange(2)-brange(1)+1 ) ) then
      write(6,*) 'Error! Band dimension of valence energies too small in qe62_read_energies_single'
      ierr = 1
      return
    endif
    if( size( valEnergies, 2 ) .lt. product(kpts(:)) ) then
      write(6,*) 'Error! K-point dimension of valence energies too small in qe62_read_energies_single'
      ierr = 233
      return
    endif
    if( size( valEnergies, 3 ) .lt. nspin ) then
      write(6,*) 'Error! Spin dimension of valence energies too small in qe62_read_energies_single'
      ierr = 3
      return
    endif
    if( size( conEnergies, 1 ) .lt. ( brange(4)-brange(3)+1 ) ) then
      write(6,*) 'Error! Band dimension of conduction energies too small in qe62_read_energies_single'
      ierr = 5
      return
    endif
    if( size( conEnergies, 2 ) .lt. product(kpts(:)) ) then
      write(6,*) 'Error! K-point dimension of conduction energies too small in qe62_read_energies_single'
      ierr = 6
      return
    endif
    if( size( conEnergies, 3 ) .lt. nspin ) then
      write(6,*) 'Error! Spin dimension of conduction energies too small in qe62_read_energies_single'
      ierr = 7
      return
    endif

    nb = brange(2)-brange(1)+1 
    nk = product(kpts(:))
    valEnergies( 1:nb, 1:nk, : ) = internal_val_energies( :, :, : )
    nb = brange(4)-brange(3)+1
    conEnergies( 1:nb, 1:nk, : ) = internal_con_energies( :, :, : )

  end subroutine qe62_read_energies_split

  subroutine qe62_read_energies_single( myid, root, comm, energies, ierr )
#ifdef MPI
    use ocean_mpi, only : MPI_DOUBLE_PRECISION
#endif
    integer, intent( in ) :: myid, root
#ifdef MPI_F08
    type( MPI_COMM ), intent( in ) :: comm
#else
    integer, intent( in ) :: comm
#endif
    real( DP ), intent( out ) :: energies( :, :, : )
    integer, intent( inout ) :: ierr
    !
    integer :: ispn, ikpt, bstop2, bstart, bstop1

    if( is_init .eqv. .false. ) then
      write(6,*) 'qe62_read_energies_single called but was not initialized'
      ierr = 4
      return
    endif 

    if( size( energies, 1 ) .lt. ( bands(2)-bands(1)+1 ) ) then
      write(6,*) 'Error! Band dimension of energies too small in qe62_read_energies_single'
      ierr = 1
      return
    endif
    if( size( energies, 2 ) .lt. product(kpts(:)) ) then
      write(6,*) 'Error! K-point dimension of energies too small in qe62_read_energies_single'
      ierr = 234
      return
    endif
    if( size( energies, 3 ) .lt. nspin ) then
      write(6,*) 'Error! Spin dimension of energies too small in qe62_read_energies_single'
      ierr = 3
      return
    endif

    bstop1 = brange(2) - brange(1) + 1
    bstart = brange(2) - brange(3) + 2
    bstop2 = bands(2) - brange(3) + 1
    do ispn = 1, nspin
      do ikpt = 1, product( kpts(:) )
        energies( 1 : bstop1, ikpt, ispn ) = internal_val_energies( :, ikpt, ispn )
        energies( bstop1+1:bands(2), ikpt, ispn )  = internal_con_energies( bstart:bstop2, ikpt, ispn )
      enddo
    enddo

  end subroutine qe62_read_energies_single

#if 0
  pure function qe62_eigFile( ikpt, ispin, isConduction ) result( fileName )
    integer, intent ( in ) :: ikpt, ispin
    logical, intent( in ), optional :: isConduction
    character(len=512) :: fileName

    integer :: ik
    logical :: is_
    character(len=13) :: eigString

    is_ = .false.
    if( present( isConduction ) ) is_ = isConduction

    if( nspin .eq. 1 ) then
      eigString = 'eigenval.xml'
    elseif( ispin .eq. 1 ) then
      eigString = 'eigenval1.xml'
    else
      eigString = 'eigenval2.xml'
    endif

    if( is_shift ) then
      if( is_split ) then  ! Different directories, k-point counting is correct!
        if( is_ ) then
          write( fileName, '(a,a1,i5.5,a1,a)' ) trim( prefixSplit ), 'K', ikpt, '/', trim(eigString)
        else
          write( fileName, '(a,a1,i5.5,a1,a)' ) trim( prefix ), 'K', ikpt, '/', trim(eigString)
        endif
      else  ! same directory, k-points are lies! 
        ik = ( ikpt * 2 ) - 1
        if( is_ ) ik = ik + 1
        write( fileName, '(a,a1,i5.5,a1,a)' ) trim( prefix ), 'K', ik, '/', trim(eigString)
      endif
    else
      write( fileName, '(a,a1,i5.5,a1,a)' ) trim( prefix ), 'K', ikpt, '/', trim(eigString)
    endif

  end function qe62_eigFile
#endif

  ! unlike for qe54, the gvectors are stored at the top of the wavefunction files
  ! just call through
  pure function qe62_gkvFile( ikpt, ispin, isConduction ) result( fileName )
    integer, intent ( in ) :: ikpt, ispin
    logical, intent( in ), optional :: isConduction
    character(len=512) :: fileName

    if( present( isConduction ) ) then
      fileName = qe62_evcFile( ikpt, ispin, isConduction )
    else
      fileName = qe62_evcFile( ikpt, ispin )
    endif
  end function qe62_gkvFile

  pure function qe62_evcFile( ikpt, ispin, isConduction ) result( fileName )
    integer, intent ( in ) :: ikpt, ispin
    logical, intent( in ), optional :: isConduction
    character(len=512) :: fileName

    integer :: ik
    logical :: is_
    character(len=5) :: evcString

    is_ = .false.
    if( present( isConduction ) ) is_ = isConduction

    if( nspin .eq. 1 ) then
      evcString = 'wfc'
    elseif( ispin .eq. 1 ) then
      evcString = 'wfcup'
    else
      evcString = 'wfcdw'
    endif

    if( is_shift ) then
      if( is_split ) then  ! Different directories, k-point counting is correct!
        if( is_ ) then
          write( fileName, '(a,a,i0,a)' ) trim( prefixSplit ), trim(evcString), ikpt, '.dat'
        else
          write( fileName, '(a,a,i0,a)' ) trim( prefix ), trim(evcString), ikpt, '.dat'
        endif
      else  ! same directory, k-points are lies! 
        ik = ( ikpt * 2 ) - 1
        if( is_ ) ik = ik + 1
        write( fileName, '(a,a,i0,a)' ) trim( prefix ), trim(evcString), ik, '.dat'
      endif
    else
      write( fileName, '(a,a,i0,a)' ) trim( prefix ), trim(evcString), ikpt, '.dat'
    endif

  end function qe62_evcFile

#if 0
  subroutine qe62_read_energies( myid, root, comm, nbv, nbc, nkpts, nspns, val_energies, con_energies, ierr )
#ifdef MPI
    use ocean_mpi, only : MPI_DOUBLE_PRECISION
#endif
    integer, intent( in ) :: myid, root, nbv, nbc, nkpts, nspns
#ifdef MPI_F08
    type( MPI_COMM ), intent( in ) :: comm
#else
    integer, intent( in ) :: comm
#endif
    real( DP ), intent( out ) :: val_energies( nbv, nkpts, nspns ), con_energies( nbv, nkpts, nspns )
    integer, intent( inout ) :: ierr
    !
    integer :: ispn, ikpt

    if( myid .eq. root ) then
      open( unit=99, file='enkfile', form='formatted', status='old' )
      do ispn = 1, nspns
        do ikpt = 1, nkpts
          read( 99, * ) val_energies( :, ikpt, ispn )
          read( 99, * ) con_energies( :, ikpt, ispn )
        enddo
      enddo
      close( 99 )
    endif

#ifdef MPI
    call MPI_BCAST( val_energies, nbv*nkpts*nspns, MPI_DOUBLE_PRECISION, root, comm, ierr )
    call MPI_BCAST( con_energies, nbc*nkpts*nspns, MPI_DOUBLE_PRECISION, root, comm, ierr )
#endif

  end subroutine qe62_read_energies
#endif



  subroutine qe62_clean( ierr )
    integer, intent( inout ) :: ierr
    !
    nfiles = 0

#ifdef MPI
    call MPI_COMM_FREE( pool_comm, ierr )
    if( ierr .ne. 0 ) return
    call MPI_COMM_FREE( inter_comm, ierr )
    if( ierr .ne. 0 ) return
#endif
    deallocate( internal_val_energies, internal_con_energies )

  end subroutine qe62_clean

  ! Read the universal little files
  subroutine qe62_read_init( comm, isGamma, isFullStorage, ierr )
    use ocean_mpi, only : MPI_INTEGER, MPI_CHARACTER, MPI_LOGICAL, MPI_DOUBLE_PRECISION
#ifdef MPI_F08
    type( MPI_COMM ), intent( in ) :: comm
#else
    integer, intent( in ) :: comm
#endif
    logical, intent( out ) :: isGamma, isFullStorage
    integer, intent( inout ) :: ierr
    !
    integer :: i, j, nkpts, nbv, nbc, ierr_
    integer :: test_brange(4), test_nk, test_nspin
    logical :: ex
    character(len=128) :: tmp
    real(DP), allocatable :: tve(:,:,:), tce(:,:,:)
    real(DP) :: qinb(3)
    real(DP), parameter :: tol = 0.0000001_DP
    !
    ! Set the comms for file handling
    call MPI_COMM_DUP( comm, inter_comm, ierr )
    if( ierr .ne. 0 ) return
    call MPI_COMM_SIZE( inter_comm, inter_nproc, ierr )
    if( ierr .ne. 0 ) return
    call MPI_COMM_RANK( inter_comm, inter_myid, ierr )
    if( ierr .ne. 0 ) return


    if( inter_myid .eq. inter_root ) then
      open( unit=99, file='prefix', form='formatted', status='old' )
      read(99,*)  tmp
      close( 99 )
      write( prefix, '(a,a,a)' ) 'Out/', trim(tmp), '.save/'
      write( prefixSplit, '(a,a,a)' ) 'Out_shift/', trim(tmp), '.save/'

      open(unit=99,file='brange.ipt', form='formatted', status='old' )
      read(99,*) brange(:)
      close(99)

      inquire( file='bands.ipt', exist=ex )
      if( ex ) then
        open(unit=99,file='bands.ipt', form='formatted', status='old' )
        read(99,*) bands(:)
        close(99)
      else
!        open(unit=99,file='brange.ipt', form='formatted', status='old' )
!        read(99,*) brange(:)
!        close(99)
        bands(2) = brange(4)
        bands(1) = brange(1)
      endif
      open(unit=99,file='kmesh.ipt', form='formatted', status='old' )
      read(99,*) kpts(:)
      close(99)
      open(unit=99,file='nspin', form='formatted', status='old' )
      read(99,*) nspin
      close(99)

      inquire( file='gamma', exist=ex )
      if( ex ) then
        open(unit=99,file='gamma', form='formatted', status='old' )
        read(99,*) is_gamma
        close(99)
      else
        is_gamma = .false.
      endif


      inquire( file='qinunitsofbvectors.ipt', exist=ex )
      if( ex ) then
        open( unit=99, file='qinunitsofbvectors.ipt', form='formatted', status='old')
        read( 99 , * ) qinb(:)
        close( 99 )
        if( abs( qinb(1) ) + abs( qinb(2) ) + abs( qinb(3) ) > tol ) is_shift = .true.
      else
        is_shift = .false.
      endif

      is_split = .false.
      if( is_shift ) then 
        inquire( file='dft.split', exist=ex )
        if( ex ) then
          open( unit=99, file='dft.split', form='formatted', status='old')
          read( 99, * ) is_split
          close( 99 )
        endif
      endif
!      if( is_split ) is_shift = .true.

      nfiles = nspin * product(kpts(:) )

      

      nkpts = product(kpts(:) )
      nbv = brange(2)-brange(1) + 1
      nbc = brange(4)-brange(3) + 1
      allocate( internal_val_energies( nbv, nkpts, nspin ), internal_con_energies( nbc, nkpts, nspin ) )

      inquire( file='enkfile_raw', exist=ex )
      if( ex ) then
        open( unit=99, file='enkfile_raw', form='formatted', status='old')
        do j = 1, nspin
          do i = 1, nkpts
            read(99,*) internal_val_energies( :, i, j )
            read(99,*) internal_con_energies( :, i, j )
          enddo
        enddo
        close(99)
        internal_val_energies( :, :, : ) = internal_val_energies( :, :, : ) * 0.5_DP
        internal_con_energies( :, :, : ) = internal_con_energies( :, :, : ) * 0.5_DP
      else
        inquire( file='QE_EIGS.txt', exist=ex )
        if( .not. ex ) then
          ierr = 6572
          return
        endif

        open( unit=99, file='QE_EIGS.txt', form='formatted', status='old')
        read(99,*) test_brange(:), test_nk, test_nspin
        if( test_brange(1) .gt. brange(1) ) ierr = 6573
        if( test_brange(2) .lt. brange(2) ) ierr = 6574
        if( .not. is_split ) then
          if( test_brange(3) .gt. brange(3) ) ierr = 6575
          if( test_brange(4) .lt. brange(4) ) ierr = 6576
        endif
        if( test_nk .ne. nkpts ) ierr = 6577
        if( test_nspin .ne. nspin ) ierr = 6578
        if( ierr .ne. 0 ) return

        allocate( tve( test_brange(1):test_brange(2), nkpts, nspin ),  &
                  tce( test_brange(3):test_brange(4), nkpts, nspin ) )
        do j = 1, nspin
          do i = 1, nkpts
            read(99,*) tve( :, i, j )
            read(99,*) tce( :, i, j )
          enddo
        enddo
        close( 99 )
        internal_val_energies( :, :, : ) = tve( brange(1):brange(2), :, : ) * 0.5_DP
        if( .not. is_split ) then
          internal_con_energies( :, :, : ) = tce( brange(3):brange(4), :, : ) * 0.5_DP
        endif
        deallocate( tve, tce )

        ! If split then we need to re-read the conductions, 
        if( is_split ) then
          inquire( file='QE_EIGS_shift.txt', exist=ex )
          if( .not. ex ) then
            ierr = 6579
            return
          endif
            
          open( unit=99, file='QE_EIGS_shift.txt', form='formatted', status='old')
          read(99,*) test_brange(:), test_nk, test_nspin
          if( test_brange(3) .gt. brange(3) ) ierr = 6582
          if( test_brange(4) .lt. brange(4) ) ierr = 6583
          if( test_nk .ne. nkpts ) ierr = 6580
          if( test_nspin .ne. nspin ) ierr = 6581
          if( ierr .ne. 0 ) return 
          
          allocate( tve( test_brange(1):test_brange(2), nkpts, nspin ),  &
                    tce( test_brange(3):test_brange(4), nkpts, nspin ) )
          do j = 1, nspin
            do i = 1, nkpts
              read(99,*) tve( :, i, j )
              read(99,*) tce( :, i, j )
            enddo
          enddo
          close( 99 )
          internal_con_energies( :, :, : ) = tce( brange(3):brange(4), :, : ) * 0.5_DP
          deallocate( tve, tce )
        endif


      endif

    endif
#ifdef MPI
      call MPI_BCAST( ierr, 1, MPI_INTEGER, inter_root, inter_comm, ierr_ )
      if( ierr .ne. 0 ) return
      if( ierr_ .ne. 0 ) then
        ierr = ierr_
        return
      endif

    call MPI_BCAST( nfiles, 1, MPI_INTEGER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( bands, 2, MPI_INTEGER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( brange, 4, MPI_INTEGER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( kpts, 3, MPI_INTEGER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( nspin, 1, MPI_INTEGER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( prefix, len(prefix), MPI_CHARACTER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( prefixSplit, len(prefixSplit), MPI_CHARACTER, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( is_gamma, 1, MPI_LOGICAL, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( is_shift, 1, MPI_LOGICAL, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( is_split, 1, MPI_LOGICAL, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    if( inter_myid .ne. inter_root ) then
      nkpts = product(kpts(:) )
      nbv = brange(2)-brange(1) + 1
      nbc = brange(4)-brange(3) + 1
      allocate( internal_val_energies( nbv, nkpts, nspin ), internal_con_energies( nbc, nkpts, nspin ) )
    endif
    call MPI_BCAST( internal_val_energies, nbv * nkpts * nspin, MPI_DOUBLE_PRECISION, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_BCAST( internal_con_energies, nbc * nkpts * nspin, MPI_DOUBLE_PRECISION, inter_root, inter_comm, ierr )
    if( ierr .ne. 0 ) return
#endif

    call set_pools( ierr )
    if( ierr .ne. 0 ) return

    call writeDiagnostics( )

!    write(6,*) 'qe62_read_init was successful'
    is_init = .true.
    isGamma = is_gamma

    if( isGamma ) then
      isFullStorage = gammaFullStorage
    else
      isFullStorage = .true.
    endif
  
  end subroutine  qe62_read_init 

  subroutine writeDiagnostics( )
    if( inter_myid .eq. inter_root ) then
      write( 6, '(A)' ) "    #############################"
      write( 6, '(A,I8)' ) " Npools:      ", npool
      write( 6, '(A,I8)' ) " Nprocs/pool: ", pool_nproc
    endif

    write(1000+inter_myid, '(A)' ) "    #############################"
    write(1000+inter_myid, '(A,I8)' ) " Npools:      ", npool
    write(1000+inter_myid, '(A,I8)' ) " Nprocs/pool: ", pool_nproc
    write(1000+inter_myid, '(A,I8)' ) " My pool:     ", mypool
    write(1000+inter_myid, '(A,I8)' ) " My pool id:  ", pool_myid
    write(1000+inter_myid, '(A,I8)' ) " My bands:    ", pool_nbands
    write(1000+inter_myid, '(A,I8)' ) " My con bands:", pool_con_nbands
    write(1000+inter_myid, '(A,I8)' ) " My val bands:", pool_val_nbands


    write(1000+inter_myid, '(A)' ) "    #############################"
!    flush(1000+inter_myid)
  end subroutine 

  subroutine set_pools( ierr )
    use ocean_mpi, only : MPI_INTEGER
    integer, intent( inout ) :: ierr
    !
    integer :: i, inter_nproc_
    logical :: ex

    npool = 0
    inter_nproc_ = inter_nproc
    if( inter_myid .eq. 0 ) then
      inquire( file='nproc_wvfn', exist=ex )
      if( ex ) then
        open( unit=99, file='nproc_wvfn', form='formatted', status='old')
!        read(99,*) inter_nproc
        close(99)
        write(6,*) 'nproc_wvfn not enabled yet'
      endif
      inquire( file='npool', exist=ex )
      if( ex ) then
        open( unit=99, file='npool', form='formatted', status='old')
        read(99,*) npool
        close(99)
!        if( npool .gt. inter_nproc .or. mod( inter_nproc, npool ) .ne. 0 ) npool = 0
        if( npool .gt. inter_nproc ) npool = 0
      endif
    endif
    call MPI_BCAST( npool, 1, MPI_INTEGER, 0, inter_comm, ierr )
    if( ierr .ne. 0 ) return

    if( npool .ne. 0 ) then
      i = inter_nproc / npool
      mypool = inter_myid/ i 
      if( inter_myid .eq. 0 ) write(6,*) i, inter_nproc
      write(1000+inter_myid,*)  i, inter_nproc, nfiles

    elseif( nfiles .ge. inter_nproc ) then
      mypool = inter_myid
      npool = inter_nproc

    else
      do i = 2, inter_nproc
        if( mod( inter_nproc, i ) .eq. 0 ) then
          if( inter_myid .eq. 0 ) write(6,*) i, inter_nproc
          write(1000+inter_myid,*)  i, inter_nproc, nfiles
          if( nfiles .ge. (inter_nproc/i) ) then
            npool = inter_nproc/i
            mypool = inter_myid/ i 
#ifdef DEBUG
            write(6,*) '*', inter_myid, npool, mypool
#endif
            goto 11
          endif
        endif
      enddo
11    continue
    endif

!    ! if we've reduced the number of processors for i/o, then put them in their own comm
!    if( inter_myid .ge. inter_nproc ) mypool = inter_nproc_
    
    call MPI_COMM_SPLIT( inter_comm, mypool, inter_myid, pool_comm, ierr )
    if( ierr .ne. 0 ) return

    call MPI_COMM_RANK( pool_comm, pool_myid, ierr )
    if( ierr .ne. 0 ) return
    call MPI_COMM_SIZE( pool_comm, pool_nproc, ierr )
    if( ierr .ne. 0 ) return


    pool_nbands = qe62_getAllBandsForPoolID( pool_myid )
    pool_con_nbands = qe62_getConductionBandsForPoolID( pool_myid )
    pool_val_nbands = qe62_getValenceBandsForPoolID( pool_myid )
!    nbands_left = brange(4)-brange(3)+brange(2)-brange(1)+2
!    do i = 0, pool_nproc-1
!      nbands = nbands_left / ( pool_nproc - i )
!      if( i .eq. pool_myid ) pool_nbands = nbands
!      nbands_left = nbands_left - nbands
!    enddo

  end subroutine set_pools

  subroutine qe62_read_gvecs_at_kpt( ikpt, ispin, gvecs, ierr )
    use OCEAN_mpi
    integer, intent( in ) :: ikpt, ispin
    integer, intent( out ) :: gvecs(:,:)
    integer, intent( inout ) :: ierr
    !
    integer :: i, crap, ngvecs, j, k
    logical :: is_kpt

    call qe62_is_my_kpt( ikpt, ispin, is_kpt, ierr )
    if( ierr .ne. 0 ) return
    if( is_kpt .eqv. .false. ) then
      return
    endif

    if( pool_myid .eq. pool_root ) then
      write(myid+1000,*) 'Opening file ', trim(qe62_gkvFile( ikpt, ispin ))
!      flush(myid+1000)
      open( unit=99,file=trim(qe62_gkvFile( ikpt, ispin )), form='unformatted', status='old' )
      read( 99 )
      read(99) crap, ngvecs
      ! Miller indicies
      read( 99 )
      ! Using test_gvec for gamma support
      read( 99 ) gvecs( :, 1:ngvecs )
      close( 99 )

      ! Expand and grab the -gvecs too, except for 0,0,0 where there is no -
      if( gammaFullStorage .and. is_gamma ) then
        j = ngvecs
        do i = 1, ngvecs
          if( gvecs(1,i) .eq. 0 .and. gvecs(2,i) .eq. 0 .and. gvecs(3,i) .eq. 0 ) then
            k = i + 1
            exit
          endif
          j = j + 1
          gvecs(:,j) = -gvecs(:,i)
        enddo
        do i = k, ngvecs
          j = j + 1
          gvecs(:,j) = -gvecs(:,i)
        enddo
        ngvecs = 2 * ngvecs - 1
      endif 
    endif

!    write(6,*) 'gvecs', pool_root, pool_comm
!111 continue

#ifdef MPI
    call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, i )
    if( ierr .ne. 0 ) return
    if( i .ne. 0 ) then
      ierr = i
      return
    endif

    call MPI_BCAST( ngvecs, 1, MPI_INTEGER, pool_root, pool_comm, ierr )
    if( ierr .ne. 0 ) return
    call MPI_BCAST( gvecs, 3*ngvecs, MPI_INTEGER, pool_root, pool_comm, ierr )
    if( ierr .ne. 0 ) return
#endif
!    write(6,*) 'gvecs', pool_root, pool_comm

  end subroutine qe62_read_gvecs_at_kpt


  subroutine qe62_get_ngvecs_at_kpt( ikpt, ispin, gvecs, ierr )
    use OCEAN_mpi
    integer, intent( in ) :: ikpt, ispin
    integer, intent( out ) :: gvecs
    integer, intent( inout ) :: ierr
    !
    integer :: i, crap
    logical :: is_kpt

    call qe62_is_my_kpt( ikpt, ispin, is_kpt, ierr )
    if( ierr .ne. 0 ) return
    if( is_kpt .eqv. .false. ) then 
      gvecs = 0
      return
    endif

    if( pool_myid .eq. pool_root ) then
      write(myid+1000,*) 'Opening file ', trim(qe62_gkvFile( ikpt, ispin ))
!      flush(myid+1000)
      open( unit=99,file=trim(qe62_gkvFile( ikpt, ispin )), form='unformatted', status='old' )
      read( 99 )
      read(99) crap, gvecs
      close( 99 )
      ! Do we want to expand the coeffs inside this module?
      if( gammaFullStorage .and. is_gamma ) gvecs = 2 * gvecs - 1
    endif

!    write(6,*) 'gvecs', pool_root, pool_comm
!111 continue
    
#ifdef MPI
    call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, i )
    if( ierr .ne. 0 ) return
    if( i .ne. 0 ) then
      ierr = i
      return
    endif

    call MPI_BCAST( gvecs, 1, MPI_INTEGER, pool_root, pool_comm, ierr )
    if( ierr .ne. 0 ) return
#endif
!    write(6,*) 'gvecs', pool_root, pool_comm

  end subroutine qe62_get_ngvecs_at_kpt


  subroutine qe62_get_ngvecs_at_kpt_split( ikpt, ispin, gvecs, ierr )
    use OCEAN_mpi
    integer, intent( in ) :: ikpt, ispin
    integer, intent( out ) :: gvecs( 2 )
    integer, intent( inout ) :: ierr
    !
    integer :: i, crap
    logical :: is_kpt

    call qe62_is_my_kpt( ikpt, ispin, is_kpt, ierr )
    if( ierr .ne. 0 ) then
      write(1000+myid,*) 'Not my k-point!'
      return
    endif
    if( is_kpt .eqv. .false. ) then
      gvecs = 0
      return
    endif

    if( pool_myid .eq. pool_root ) then
      write(myid+1000,*) 'Opening file ', trim(qe62_gkvFile( ikpt, ispin, .false. ))
!      flush(myid+1000)
      open( unit=99,file=trim(qe62_gkvFile( ikpt, ispin, .false. )), form='unformatted', status='old' )
      read( 99 )
      read(99) crap, gvecs(1)
      close( 99 )
      ! Do we want to expand the coeffs inside this module?
      if( gammaFullStorage .and. is_gamma ) gvecs(1) = 2 * gvecs(1) - 1

      if( is_shift ) then
        write(myid+1000,*) 'Opening file ', trim(qe62_gkvFile( ikpt, ispin, .true. ))
!        flush(myid+1000)
        open( unit=99,file=trim(qe62_gkvFile( ikpt, ispin, .true. )), form='unformatted', status='old' )
        read( 99 )
        read(99) crap, gvecs(2)
        close( 99 )
        ! Do we want to expand the coeffs inside this module?
        if( gammaFullStorage .and. is_gamma ) gvecs(2) = 2 * gvecs(2) - 1
      else
        gvecs(2) = gvecs(1)
      endif

    endif

!111 continue

#ifdef MPI
    call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, i )
    if( ierr .ne. 0 ) return
    if( i .ne. 0 ) then
      ierr = i
      return
    endif

    call MPI_BCAST( gvecs, 2, MPI_INTEGER, pool_root, pool_comm, ierr )
    if( ierr .ne. 0 ) return
#endif

  end subroutine qe62_get_ngvecs_at_kpt_split

  subroutine qe62_read_at_kpt_split( ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands, &
                                    valGvecs, conGvecs, valUofG, conUofG, ierr )
    use ocean_mpi, only : myid

    integer, intent( in ) :: ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands
    integer, intent( out ) :: valGvecs( 3, valNgvecs ), conGvecs( 3, conNgvecs )
    complex( DP ), intent( out ) :: valUofG( valNGvecs, valBands ), conUofG( conNGvecs, conBands )
    integer, intent( inout ) :: ierr
    !
    if( qe62_getPoolIndex( ispin, ikpt ) .ne. mypool ) return
    !
    if( qe62_getValenceBandsForPoolID( pool_myid ) .ne. valBands ) then
      write(1000+myid, * ) 'Valence band mismatch:', qe62_getValenceBandsForPoolID( pool_myid ), valBands
      ierr = 1
      return
    endif
    if( qe62_getConductionBandsForPoolID( pool_myid ) .ne. conBands ) then
      write(1000+myid, * ) 'Conduction band mismatch:', qe62_getConductionBandsForPoolID( pool_myid ), conBands
      ierr = 235
      return
    endif
    
    ! Do we have different val and con states from DFT?
    if( is_shift ) then
      call shift_read_at_kpt_split( ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands, &
                                    valGvecs, conGvecs, valUofG, conUofG, ierr )
    else
      call read_at_kpt_split( ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands, &
                                    valGvecs, conGvecs, valUofG, conUofG, ierr )
    endif

  end subroutine qe62_read_at_kpt_split

  subroutine read_at_kpt_split( ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands, &
                                    valGvecs, conGvecs, valUofG, conUofG, ierr )
    use SCREEN_timekeeper, only : SCREEN_tk_start, SCREEN_tk_stop
#ifdef MPI
    use OCEAN_mpi, only : MPI_INTEGER, MPI_DOUBLE_COMPLEX, MPI_STATUSES_IGNORE, myid, &
                          MPI_REQUEST_NULL, MPI_STATUS_IGNORE, MPI_UNDEFINED
#endif
    integer, intent( in ) :: ikpt, ispin, valNGvecs, conNGvecs, valBAnds, conBands
    integer, intent( out ) :: valGvecs( 3, valNgvecs ), conGvecs( 3, conNgvecs )
    complex( DP ), intent( out ) :: valUofG( valNGvecs, valBands ), conUofG( conNGvecs, conBands )
    integer, intent( inout ) :: ierr
    !
    complex( DP ), allocatable, dimension( :, :, : ) :: cmplx_wvfn
    complex( DP ), allocatable, dimension( :, : ) :: overlap_wvfn
    integer :: test_gvec, nbands_to_send, nr, ierr_, nbands_to_read, id, start_band, & 
               i, crap, overlapBands, j, indexOverlapBand, maxBands, bufferSize, k
#ifdef MPI_F08
    type( MPI_REQUEST ), allocatable :: requests( : )
    type( MPI_DATATYPE ) :: valType, conType
#else
    integer, allocatable :: requests( : )
    integer :: valType, conType
#endif

    nbands_to_read = brange(4)-brange(3)+brange(2)-brange(1)+2

    if( pool_myid .eq. pool_root ) then

      ! get gvecs first
      open( unit=99, file=qe62_gkvFile( ikpt, ispin), form='unformatted', status='old' )
      read( 99 )
      read(99) crap, test_gvec
      ! Are we expanding the wave functions here?
      if( gammaFullStorage .and. is_gamma ) then
        if( ( 2 * test_gvec - 1 ) .ne. valngvecs ) then
          ierr = -2
          write(6,*) (2*test_gvec-1), valngvecs
          return
        endif
      else
        if( test_gvec .ne. valngvecs ) then
          ierr = -2
          write(6,*) test_gvec, valngvecs
          return
        endif
      endif

      ! Error synch. Also ensures that the other procs have posted their recvs
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 ) return
      if( ierr_ .ne. 0 ) then
        ierr = ierr_
        return
      endif

      ! Miller indicies
      read( 99 )

      ! Using test_gvec for gamma support
      read( 99 ) valGvecs( :, 1:test_gvec )

      ! Need to handle overlaps ( top of valence is bottom of conduction ) without resorting to 
      !  re-reading any of the file
      ! This can take several cases. First no overlap. This is the best case
      ! Second, the overlapped region lands entirely on the reading processor. This is also good.
      ! Third, one or more additional processors need to be sent data from the overlap region.


      ! use the same buffer system as for qe62_read_at_kpt, but make buffers the max of conduction/valence
  
!      maxBands = qe62_getConductionBandsForPoolID( 0 )
      maxBands = qe62_getValenceBandsForPoolID( 0 )
      do id = 1, pool_nproc - 1
!        maxBands = max( maxBands, qe62_getConductionBandsForPoolID( id ) )
        maxBands = max( maxBands, qe62_getValenceBandsForPoolID( id ) )
      enddo

      bufferSize = floor( 536870912.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
      bufferSize = min( bufferSize, pool_nproc - 1 )
      bufferSize = max( bufferSize, 1 )
      allocate( cmplx_wvfn( test_gvec, maxBands, bufferSize ) )

      if( brange(2) .ge. brange(3) ) then
        overlapBands = brange(2) - brange(3) + 1
        allocate( overlap_wvfn( test_gvec, overlapBands ) )
      else
        overlapBands = 0
        allocate( overlap_wvfn( 0, 0 ) )
      endif


      nr = bufferSize
      allocate( requests( 0:nr ) )
      requests = MPI_REQUEST_NULL
#ifdef MPI
      call MPI_IBCAST( valGvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 0 ), ierr )
#endif
      write(1000+myid,*) '***Reading k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', valngvecs
      write(1000+myid,*) '   Nbands: ', brange(4)-brange(1)+1
      write(1000+myid,*) '   Nbuffer:', bufferSize

!      open( unit=99, file=qe62_evcFile( ikpt, ispin), form='unformatted', status='old' )

      start_band = brange(1)
      do i = 1, start_band - 1
        read(99)
      enddo
      indexOverlapBand = 0

      do id = 0, pool_nproc - 1
        nbands_to_send = qe62_getValenceBandsForPoolID( id )

        if( id .eq. pool_myid ) then
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 99 ) valUofG( 1:test_gvec, i )
            if( start_band + i - 1 .ge. brange(3) ) then
              indexOverlapBand = indexOverlapBand + 1
              overlap_wvfn( :, indexOverlapBand ) = valUofG( 1:test_gvec, i )
            endif
          enddo
          call SCREEN_tk_stop("dft-read")

        ! IF not mine, find open buffer, read to buffer, send buffer
        else
          j = 0
          do i = 1, bufferSize
            if( requests( i ) .eq. MPI_REQUEST_NULL ) then
              j = i
              exit
            endif
          enddo
          if( j .eq. 0 ) then
            call MPI_WAITANY( bufferSize, requests(1:bufferSize), j, MPI_STATUS_IGNORE, ierr )
            write(1000+myid, * ) 'Waited for buffer:', j
            if( j .eq. MPI_UNDEFINED ) j = 1
          endif


          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 99 ) cmplx_wvfn( 1:test_gvec, i, j )
            if( start_band + i - 1 .ge. brange(3) ) then
              indexOverlapBand = indexOverlapBand + 1
              overlap_wvfn( :, indexOverlapBand ) = cmplx_wvfn( 1:test_gvec, i, j )
            endif
          enddo
          call SCREEN_tk_stop("dft-read")
      
          write(1000+myid,'(A,3(1X,I8))') '   Sending ...', id, start_band, nbands_to_send
          call MPI_IRSEND( cmplx_wvfn( 1, 1, j ), nbands_to_send*test_gvec, MPI_DOUBLE_COMPLEX, &
                         id, 1, pool_comm, requests( j ), ierr )
          if( ierr .ne. 0 ) return

        endif

        start_band = start_band + nbands_to_send
      enddo

      call MPI_WAITALL( bufferSize, requests(1:bufferSize), MPI_STATUSES_IGNORE, ierr )
      if( ierr .ne. 0 ) return
      requests(1:bufferSize) = MPI_REQUEST_NULL
      
      deallocate( cmplx_wvfn )
      maxBands = qe62_getConductionBandsForPoolID( 0 )
      do id = 1, pool_nproc - 1
        maxBands = max( maxBands, qe62_getConductionBandsForPoolID( id ) )
      enddo

      bufferSize = floor( 536870912.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
      bufferSize = min( bufferSize, pool_nproc - 1 )
      bufferSize = max( bufferSize, 1 )
      allocate( cmplx_wvfn( test_gvec, maxBands, bufferSize ) )

      start_band = 1
      
      do id = 0, pool_nproc - 1
        nbands_to_send = qe62_getConductionBandsForPoolID( id )

        ! If mine, read directly to wvfn
        if( id .eq. pool_myid ) then
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            if( start_band + i - 1 .le. overlapBands ) then
              conUofG( 1:test_gvec, i ) = overlap_wvfn( :, start_band + i - 1 )
            else
              read( 99 ) conUofG( 1:test_gvec, i )
            endif
          enddo
          call SCREEN_tk_stop("dft-read")

        ! IF not mine, find open buffer, read to buffer, send buffer
        else
          j = 0
          do i = 1, bufferSize
            if( requests( i ) .eq. MPI_REQUEST_NULL ) then
              j = i
              exit
            endif
          enddo
          if( j .eq. 0 ) then
            call MPI_WAITANY( bufferSize, requests(1:bufferSize), j, MPI_STATUS_IGNORE, ierr )
            write(1000+myid, * ) 'Waited for buffer:', j
            if( j .eq. MPI_UNDEFINED ) j = 1
          endif


          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            if( start_band + i - 1 .le. overlapBands ) then
              cmplx_wvfn( 1:test_gvec, i, j ) = overlap_wvfn( :, start_band + i - 1 )
            else
              read( 99 ) cmplx_wvfn( 1:test_gvec, i, j )
            endif
          enddo
          call SCREEN_tk_stop("dft-read")

          write(1000+myid,'(A,4(1X,I8))') '   Sending ...', id, start_band, nbands_to_send, j
          call MPI_IRSEND( cmplx_wvfn( 1, 1, j ), nbands_to_send*test_gvec, MPI_DOUBLE_COMPLEX, &
                         id, 2, pool_comm, requests( j ), ierr )
          if( ierr .ne. 0 ) return

        endif
          
        start_band = start_band + nbands_to_send
      enddo

      deallocate( overlap_wvfn )

      close( 99 )
      nr = nr+1
    else
      nr = 3
      allocate( requests( nr ), cmplx_wvfn(1,1,1) )
      requests(:) = MPI_REQUEST_NULL
      write(1000+myid,*) '***Receiving k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', valngvecs
      write(1000+myid,*) '   Nbands: ', brange(4)-brange(1)+1

      if( gammaFullStorage .and. is_gamma ) then
        test_gvec = ( valngvecs + 1 ) / 2
      else
        test_gvec = valngvecs
      endif

      write(1000+myid,*) '   Ngvecs: ', test_gvec
      write(1000+myid,*) '   Gamma : ', is_gamma

      call MPI_TYPE_VECTOR( valBands, test_gvec, valngvecs, MPI_DOUBLE_COMPLEX, valType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_COMMIT( valType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_IRECV( valUofG, 1, valType, pool_root, 1, pool_comm, requests( 1 ), ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_FREE( valType, ierr )
      if( ierr .ne. 0 ) return

      call MPI_TYPE_VECTOR( conBands, test_gvec, conngvecs, MPI_DOUBLE_COMPLEX, conType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_COMMIT( conType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_IRECV( conUofG, 1, conType, pool_root, 2, pool_comm, requests( 2 ), ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_FREE( conType, ierr )
      if( ierr .ne. 0 ) return

      call MPI_IBCAST( valGvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 3 ), ierr )
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 .or. ierr_ .ne. 0 ) then
        call MPI_CANCEL( requests( 1 ) , ierr )
        call MPI_CANCEL( requests( 2 ) , ierr )
        ierr = 5
        return
      endif

    endif ! root or not

    call MPI_WAITALL( nr, requests, MPI_STATUSES_IGNORE, ierr )
    if( ierr .ne. 0 ) return

    deallocate( cmplx_wvfn, requests )
    if( gammaFullStorage .and. is_gamma ) then
      j = test_gvec
      do i = 1, test_gvec
        if( valgvecs(1,i) .eq. 0 .and. valgvecs(2,i) .eq. 0 .and. valgvecs(3,i) .eq. 0 ) then
          k = i + 1
          exit
        endif
        j = j + 1
        valgvecs(:,j) = -valgvecs(:,i)
        valUofG(j,:) = conjg( valUofG(i,:) )
        conUofG(j,:) = conjg( conUofG(i,:) )
      enddo

      do i = k, test_gvec
        j = j + 1
        valgvecs(:,j) = -valgvecs(:,i)
        valUofG(j,:) = conjg( valUofG(i,:) )
        conUofG(j,:) = conjg( conUofG(i,:) )
      enddo
    endif
    congvecs(:,:) = valgvecs(:,:)

    write(1000+myid,*) '***Finishing k-point: ', ikpt, ispin
    call MPI_BARRIER( pool_comm, ierr )


  end subroutine read_at_kpt_split

  subroutine shift_read_at_kpt_split( ikpt, ispin, valNGvecs, conNGvecs, valBands, conBands, &
                                      valGvecs, conGvecs, valUofG, conUofG, ierr )
    use SCREEN_timekeeper, only : SCREEN_tk_start, SCREEN_tk_stop
#ifdef MPI
    use OCEAN_mpi, only : MPI_INTEGER, MPI_DOUBLE_COMPLEX, MPI_STATUSES_IGNORE, myid, &
                          MPI_REQUEST_NULL, MPI_STATUS_IGNORE, MPI_UNDEFINED
#endif
    integer, intent( in ) :: ikpt, ispin, valNGvecs, conNGvecs, valBAnds, conBands
    integer, intent( out ) :: valGvecs( 3, valNgvecs ), conGvecs( 3, conNgvecs )
    complex( DP ), intent( out ) :: valUofG( valNGvecs, valBands ), conUofG( conNGvecs, conBands )
    integer, intent( inout ) :: ierr
    !
    complex( DP ), allocatable, dimension( :, :, : ) :: cmplx_wvfn
    integer :: test_gvec, nbands_to_send, nr, ierr_, nbands_to_read, id, start_band, &
               i, crap, j, maxBands, bufferSize, k, &
               test_gvec2
#ifdef MPI_F08
    type( MPI_REQUEST ), allocatable :: requests( : )
    type( MPI_DATATYPE ) :: valType, conType
#else
    integer, allocatable :: requests( : )
    integer :: valType, conType
#endif

    nbands_to_read = brange(4)-brange(3)+brange(2)-brange(1)+2

    if( pool_myid .eq. pool_root ) then

      ! get gvecs first
      open( unit=99, file=qe62_gkvFile( ikpt, ispin), form='unformatted', status='old' )
      read( 99 )
      read(99) crap, test_gvec
      ! Are we expanding the wave functions here?
      if( gammaFullStorage .and. is_gamma ) then
        if( ( 2 * test_gvec - 1 ) .ne. valngvecs ) then
          ierr = -2
          write(6,*) (2*test_gvec-1), valngvecs
          return
        endif
      else
        if( test_gvec .ne. valngvecs ) then
          ierr = -2
          write(6,*) test_gvec, valngvecs
          return
        endif
      endif

      ! Error synch. Also ensures that the other procs have posted their recvs
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 ) return
      if( ierr_ .ne. 0 ) then
        ierr = ierr_
        return
      endif

      read( 99 )
      ! Using test_gvec for gamma support
      read( 99 ) valGvecs( :, 1:test_gvec )

      ! now get conduction band g-vecs
      open( unit=98, file=qe62_gkvFile( ikpt, ispin, .true. ), form='unformatted', status='old' )
      read( 98 )
      read(98) crap, test_gvec2
      ! Are we expanding the wave functions here?
      if( gammaFullStorage .and. is_gamma ) then
        if( ( 2 * test_gvec2 - 1 ) .ne. conngvecs ) then
          ierr = -2
          write(6,*) (2*test_gvec2-1), conngvecs
          return
        endif
      else
        if( test_gvec2 .ne. conngvecs ) then
          ierr = -2
          write(6,*) test_gvec2, conngvecs
          return
        endif
      endif

      ! Error synch. Also ensures that the other procs have posted their recvs
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 ) return
      if( ierr_ .ne. 0 ) then
        ierr = ierr_
        return
      endif


      read(98)
      ! Using test_gvec for gamma support
      read( 98 ) conGvecs( :, 1:test_gvec2 )


!      maxBands = qe62_getConductionBandsForPoolID( 0 )
      maxBands = qe62_getValenceBandsForPoolID( 0 )
      do id = 1, pool_nproc - 1
!        maxBands = max( maxBands, qe62_getConductionBandsForPoolID( id ) )
        maxBands = max( maxBands, qe62_getValenceBandsForPoolID( id ) )
      enddo

      bufferSize = floor( 536870912.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
      bufferSize = min( bufferSize, pool_nproc - 1 )
      bufferSize = max( bufferSize, 1 )
      allocate( cmplx_wvfn( test_gvec, maxBands, bufferSize ) )


      nr = bufferSize
      allocate( requests( -1:nr ) )
      requests = MPI_REQUEST_NULL
#ifdef MPI
      call MPI_IBCAST( valGvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 0 ), ierr )
      call MPI_IBCAST( conGvecs, 3*test_gvec2, MPI_INTEGER, pool_root, pool_comm, requests( -1 ), ierr )
#endif
      write(1000+myid,*) '***Reading k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', valngvecs
      write(1000+myid,*) '   Ngvecs: ', conngvecs
      write(1000+myid,*) '   Nbands: ', brange(4)-brange(1)+1
      write(1000+myid,*) '   Nbuffer:', bufferSize


      start_band = brange(1)
      do i = 1, start_band - 1
        read(99)
      enddo  

      do id = 0, pool_nproc - 1
        nbands_to_send = qe62_getValenceBandsForPoolID( id )

        if( id .eq. pool_myid ) then
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 99 ) valUofG( 1:test_gvec, i )
          enddo
          call SCREEN_tk_stop("dft-read")

        ! IF not mine, find open buffer, read to buffer, send buffer
        else
          j = 0
          do i = 1, bufferSize
            if( requests( i ) .eq. MPI_REQUEST_NULL ) then
              j = i
              exit
            endif
          enddo
          if( j .eq. 0 ) then
            call MPI_WAITANY( bufferSize, requests(1:bufferSize), j, MPI_STATUS_IGNORE, ierr )
            write(1000+myid, * ) 'Waited for buffer:', j
            if( j .eq. MPI_UNDEFINED ) j = 1
          endif


          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 99 ) cmplx_wvfn( 1:test_gvec, i, j )
          enddo
          call SCREEN_tk_stop("dft-read")

          write(1000+myid,'(A,3(1X,I8))') '   Sending ...', id, start_band, nbands_to_send
          call MPI_IRSEND( cmplx_wvfn( 1, 1, j ), nbands_to_send*test_gvec, MPI_DOUBLE_COMPLEX, &
                         id, 1, pool_comm, requests( j ), ierr )
          if( ierr .ne. 0 ) return

        endif

        start_band = start_band + nbands_to_send
      enddo
      close( 99 )
      call MPI_WAITALL( bufferSize, requests(1:bufferSize), MPI_STATUSES_IGNORE, ierr )

      deallocate( cmplx_wvfn )
      maxBands = qe62_getConductionBandsForPoolID( 0 )
      do id = 1, pool_nproc - 1
        maxBands = max( maxBands, qe62_getConductionBandsForPoolID( id ) )
      enddo

      bufferSize = floor( 536870912.0_DP /  ( real( test_gvec2, DP ) * real( maxBands, DP ) ) )
      bufferSize = min( bufferSize, pool_nproc - 1 )
      bufferSize = max( bufferSize, 1 )
      allocate( cmplx_wvfn( test_gvec2, maxBands, bufferSize ) )

      start_band = brange(3)
      do i = 1, start_band - 1
        read(98)
      enddo

      do id = 0, pool_nproc - 1
        nbands_to_send = qe62_getConductionBandsForPoolID( id )

        ! If mine, read directly to wvfn
        if( id .eq. pool_myid ) then
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 98 ) conUofG( 1:test_gvec2, i )
          enddo
          call SCREEN_tk_stop("dft-read")

        ! IF not mine, find open buffer, read to buffer, send buffer
        else
          j = 0
          do i = 1, bufferSize
            if( requests( i ) .eq. MPI_REQUEST_NULL ) then
              j = i
              exit
            endif
          enddo
          if( j .eq. 0 ) then
            call MPI_WAITANY( bufferSize, requests(1:bufferSize), j, MPI_STATUS_IGNORE, ierr )
            write(1000+myid, * ) 'Waited for buffer:', j
            if( j .eq. MPI_UNDEFINED ) j = 1
          endif
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
            read( 98 ) cmplx_wvfn( 1:test_gvec2, i, j )
          enddo
          call SCREEN_tk_stop("dft-read")

          write(1000+myid,'(A,3(1X,I8))') '   Sending ...', id, start_band, nbands_to_send
          call MPI_IRSEND( cmplx_wvfn( 1, 1, j ), nbands_to_send*test_gvec2, MPI_DOUBLE_COMPLEX, &
                         id, 2, pool_comm, requests( j ), ierr )
          if( ierr .ne. 0 ) return

        endif

        start_band = start_band + nbands_to_send
      enddo


      close( 98 )
      nr = nr+2
    else
      nr = 4
      allocate( requests( nr ), cmplx_wvfn(1,1,1) )
      requests(:) = MPI_REQUEST_NULL
      write(1000+myid,*) '***Receiving k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', valngvecs
      write(1000+myid,*) '   Ngvecs: ', conngvecs
      write(1000+myid,*) '   Nbands: ', brange(4)-brange(1)+1

      if( gammaFullStorage .and. is_gamma ) then
        test_gvec = ( valngvecs + 1 ) / 2
        test_gvec2 = ( conngvecs + 1 ) / 2
      else
        test_gvec = valngvecs
        test_gvec2 = conngvecs
      endif

      write(1000+myid,*) '   Ngvecs: ', test_gvec
      write(1000+myid,*) '   Gamma : ', is_gamma

      call MPI_TYPE_VECTOR( valBands, test_gvec, valngvecs, MPI_DOUBLE_COMPLEX, valType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_COMMIT( valType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_IRECV( valUofG, 1, valType, pool_root, 1, pool_comm, requests( 1 ), ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_FREE( valType, ierr )
      if( ierr .ne. 0 ) return

      call MPI_TYPE_VECTOR( conBands, test_gvec, conngvecs, MPI_DOUBLE_COMPLEX, conType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_COMMIT( conType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_IRECV( conUofG, 1, conType, pool_root, 2, pool_comm, requests( 2 ), ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_FREE( conType, ierr )
      if( ierr .ne. 0 ) return

      call MPI_IBCAST( valGvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 3 ), ierr )
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 .or. ierr_ .ne. 0 ) then
        call MPI_CANCEL( requests( 1 ) , ierr )
        call MPI_CANCEL( requests( 2 ) , ierr )
        ierr = 5
        return
      endif
      call MPI_BCAST( conGvecs, 3*test_gvec2, MPI_INTEGER, pool_root, pool_comm, requests( 4 ), ierr )
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 .or. ierr_ .ne. 0 ) then
        call MPI_CANCEL( requests( 1 ) , ierr )
        call MPI_CANCEL( requests( 2 ) , ierr )
        ierr = 5
        return
      endif

    endif ! root or not

    call MPI_WAITALL( nr, requests, MPI_STATUSES_IGNORE, ierr )
    if( ierr .ne. 0 ) return

    deallocate( cmplx_wvfn, requests )
    if( gammaFullStorage .and. is_gamma ) then
      j = test_gvec
      do i = 1, test_gvec
        if( valgvecs(1,i) .eq. 0 .and. valgvecs(2,i) .eq. 0 .and. valgvecs(3,i) .eq. 0 ) then
          k = i + 1
          exit
        endif
        j = j + 1
        valgvecs(:,j) = -valgvecs(:,i)
        valUofG(j,:) = conjg( valUofG(i,:) )
      enddo

      do i = k, test_gvec
        j = j + 1
        valgvecs(:,j) = -valgvecs(:,i)
        valUofG(j,:) = conjg( valUofG(i,:) )
      enddo
      j = test_gvec2
      do i = 1, test_gvec2
        if( congvecs(1,i) .eq. 0 .and. congvecs(2,i) .eq. 0 .and. congvecs(3,i) .eq. 0 ) then
          k = i + 1
          exit
        endif
        j = j + 1
        congvecs(:,j) = -congvecs(:,i)
        conUofG(j,:) = conjg( conUofG(i,:) )
      enddo

      do i = k, test_gvec2
        j = j + 1
        congvecs(:,j) = -congvecs(:,i)
        conUofG(j,:) = conjg( conUofG(i,:) )
      enddo
    endif

    write(1000+myid,*) '***Finishing k-point: ', ikpt, ispin
    call MPI_BARRIER( pool_comm, ierr )


  end subroutine shift_read_at_kpt_split

  subroutine qe62_read_at_kpt_mpi( ikpt, ispin, ngvecs, my_bands, gvecs, wfns, ierr )
#ifdef MPI
    use OCEAN_mpi, only : MPI_INTEGER, MPI_DOUBLE_COMPLEX, MPI_STATUSES_IGNORE, myid, MPI_REQUEST_NULL, &
                          MPI_STATUS_IGNORE, MPI_UNDEFINED, MPI_OFFSET_KIND, MPI_MODE_RDONLY, MPI_INFO_NULL, &
                          MPI_STATUS_SIZE
!    use OCEAN_mpi
#endif
    use SCREEN_timekeeper, only : SCREEN_tk_start, SCREEN_tk_stop
    integer, intent( in ) :: ikpt, ispin, ngvecs, my_bands
    integer, intent( out ) :: gvecs( 3, ngvecs )
    complex( DP ), intent( out ) :: wfns( ngvecs, my_bands )
    integer, intent( inout ) :: ierr
    !
    integer :: fh, i, j, k,  nbands, nbands_to_send, id, test_gvec
    integer(MPI_OFFSET_KIND ) :: offset
#ifdef MPI_F08
    TYPE(MPI_Status) :: stats
#else
    integer :: stats( MPI_STATUS_SIZE )
#endif

#ifndef MPI
    call qe62_read_at_kpt( ikpt, ispin, ngvecs, my_bands, gvecs, wfns, ierr )
    return
#endif

#ifdef MPI
    if( qe62_getPoolIndex( ispin, ikpt ) .ne. mypool ) return
    !
    if( qe62_getAllBandsForPoolID( pool_myid ) .ne. my_bands ) then
      ierr = 1
      return
    endif

    nbands = bands(2)-bands(1)+1


    call SCREEN_tk_start("dft-read")
    call MPI_FILE_OPEN( pool_comm, qe62_gkvFile( ikpt, ispin), MPI_MODE_RDONLY, MPI_INFO_NULL, fh, ierr )
    if( ierr .ne. 0 ) return

    offset = 6 * 4 + 1 * 4 + 4 * 8
    call MPI_FILE_READ_AT_ALL( fh, offset, test_gvec, 1, MPI_INTEGER, MPI_STATUS_IGNORE, ierr )
    if( ierr .ne. 0 ) return
    offset = offset + 4 * 4

    ! Are we expanding the wave functions here?
    if( gammaFullStorage .and. is_gamma ) then
      if( ( 2 * test_gvec - 1 ) .ne. ngvecs ) then
        ierr = -2
        write(6,*) (2*test_gvec-1), ngvecs
        return
      endif
    else
      if( test_gvec .ne. ngvecs ) then
        ierr = -2
        write(6,*) test_gvec, ngvecs
        return
      endif
    endif


    ! read 9 doubles
    offset = offset + 2 * 4 + 9 * 8
    offset = offset + 4
    call MPI_FILE_READ_AT_ALL( fh, offset, gvecs, 3 * test_gvec, MPI_INTEGER, MPI_STATUS_IGNORE, ierr )
    if( ierr .ne. 0 ) return
    ! 12 = 3 * 4
    offset = offset + int( test_gvec * 12, MPI_OFFSET_KIND )
    
    write(1000+myid,*) '***Reading k-point: ', ikpt, ispin
    write(1000+myid,*) '   Ngvecs: ', ngvecs
    write(1000+myid,*) '   Nbands: ', nbands

    ! loop over each proc in this pool to read wavefunctions
    do id = 0, pool_nproc - 1
      nbands_to_send = qe62_getAllBandsForPoolID( id )
    
      if( pool_myid .eq. id ) then
        j = 0
        write(1000+myid,*) '***Reading', offset, j
        do i = 1, nbands_to_send
          offset = offset + 2 * 4
!          call MPI_FILE_READ_AT( fh, offset, wfns(:,i), test_gvec, MPI_DOUBLE_COMPLEX, MPI_STATUS_IGNORE, ierr )
          call MPI_FILE_READ_AT( fh, offset, wfns(:,i), test_gvec, MPI_DOUBLE_COMPLEX, stats, ierr )
          if( ierr .ne. 0 ) return
          call MPI_GET_COUNT( stats, MPI_DOUBLE_COMPLEX, k, ierr )
          j = j + k
          offset = offset + int( test_gvec * 16, MPI_OFFSET_KIND )
        enddo
        write(1000+myid,*) '***       ', offset, j
      else
        do i = 1, nbands_to_send
          ! two ints for stop/start and then the double complex coeffs
          offset = offset + int( 8 + test_gvec * 16, MPI_OFFSET_KIND )
        enddo
      endif
    enddo

    call MPI_FILE_CLOSE( fh, ierr )
    call SCREEN_tk_stop("dft-read")
    if( gammaFullStorage .and. is_gamma ) then
      j = test_gvec
      do i = 1, test_gvec
        if( gvecs(1,i) .eq. 0 .and. gvecs(2,i) .eq. 0 .and. gvecs(3,i) .eq. 0 ) then
          k = i + 1
          exit
        endif
        j = j + 1
        gvecs(:,j) = -gvecs(:,i)
        wfns(j,:) = conjg( wfns(i,:) )
      enddo

      do i = k, test_gvec
        j = j + 1
        gvecs(:,j) = -gvecs(:,i)
        wfns(j,:) = conjg( wfns(i,:) )
      enddo
    endif
    write(1000+myid,*) '***Finishing k-point: ', ikpt, ispin
    call MPI_BARRIER( pool_comm, ierr )


#endif
  end subroutine qe62_read_at_kpt_mpi

  subroutine qe62_read_at_kpt( ikpt, ispin, ngvecs, my_bands, gvecs, wfns, ierr )
#ifdef MPI
    use OCEAN_mpi, only : MPI_INTEGER, MPI_DOUBLE_COMPLEX, MPI_STATUSES_IGNORE, myid, MPI_REQUEST_NULL, &
                          MPI_STATUS_IGNORE, MPI_UNDEFINED, MPI_OFFSET_KIND, MPI_MODE_RDONLY, MPI_INFO_NULL
!    use OCEAN_mpi
#endif
    use SCREEN_timekeeper, only : SCREEN_tk_start, SCREEN_tk_stop
    integer, intent( in ) :: ikpt, ispin, ngvecs, my_bands
    integer, intent( out ) :: gvecs( 3, ngvecs )
    complex( DP ), intent( out ) :: wfns( ngvecs, my_bands )
    integer, intent( inout ) :: ierr
    !
    complex( DP ), allocatable, dimension( :, :, : ) :: cmplx_wvfn
    integer :: test_gvec, nbands_to_send, nr, ierr_, nbands, id, start_band, crap, i, j, k, bufferSize, maxBands
    integer :: igb, jgb, doubleBufferLoop, gb
#ifdef MPI_F08
    type( MPI_REQUEST ), allocatable :: requests( : )
    type( MPI_DATATYPE ) :: newType
#else
    integer, allocatable :: requests( : )
    integer :: newType
#endif
    ! intentionally 2MB in double complex
    ! 1MB, 512k
    integer, parameter :: dblBufSize = 65536 ! 131072

    integer :: fh
    integer(MPI_OFFSET_KIND ) :: offset
    integer, allocatable :: iread(:)
    real(DP), allocatable :: dread(:)
    logical :: lread, ioWorkaround

#ifndef TRYMPI
    fh = 0
    offset = 0
#endif
#ifdef MPI
    if( ngvecs .gt. dblBufSize ) then
      call qe62_read_at_kpt_mpi( ikpt, ispin, ngvecs, my_bands, gvecs, wfns, ierr )
      return
    endif
#endif

    if( qe62_getPoolIndex( ispin, ikpt ) .ne. mypool ) return
    !
    if( qe62_getAllBandsForPoolID( pool_myid ) .ne. my_bands ) then
      ierr = 1
      return
    endif

    nbands = bands(2)-bands(1)+1

    if( gammaFullStorage .and. is_gamma ) then
      test_gvec = ( ngvecs + 1 ) / 2
    else
      test_gvec = ngvecs
    endif

    if( test_gvec .gt. dblBufSize ) then
      ioWorkaround = .true.
    else
      ioWorkaround = .false.
    endif
    ioWorkaround = .true.
!# define TRYMPI
#ifdef TRYMPI
    if( ioWorkaround ) then
      call MPI_FILE_OPEN( pool_comm, qe62_gkvFile( ikpt, ispin), MPI_MODE_RDONLY, MPI_INFO_NULL, fh, ierr )
      if( ierr .ne. 0 ) return 
    endif
#endif


    if( pool_myid .eq. pool_root ) then
!      if( gammaFullStorage .and. is_gamma ) then
!        test_gvec = ( ngvecs + 1 ) / 2
!      else
!        test_gvec = ngvecs 
!      endif
!
!      if( test_gvec .gt. dblBufSize ) then
!        ioWorkaround = .true.
!      else
!        ioWorkaround = .false.
!      endif
!      ioworkaround = .false.
    
      ! get gvecs first
      if( ioWorkaround ) then
#ifdef TRYMPI
        ! Right now the file is in byte mode
        offset = 6 * 4 + 1 * 4 + 4 * 8 
        call MPI_FILE_READ_AT( fh, offset, test_gvec, 1, MPI_INTEGER, MPI_STATUS_IGNORE, ierr )
        if( ierr .ne. 0 ) return
        offset = offset + 4 * 4
#else
        open( unit=99, file=qe62_gkvFile( ikpt, ispin), form='unformatted', status='old', &
              access='stream' )!,READONLY )
        ! int, real(3), int, logical, real
        allocate( iread(4), dread(4) )
        read( 99 ) iread(:), dread(:), lread
        read( 99 ) crap, crap, test_gvec, crap, crap, crap
        deallocate( iread, dread )
#endif
      else
        open( unit=99, file=qe62_gkvFile( ikpt, ispin), form='unformatted', status='old' )
        read( 99 )
        read(99) crap, test_gvec
      endif
      ! Are we expanding the wave functions here?
      if( gammaFullStorage .and. is_gamma ) then
        if( ( 2 * test_gvec - 1 ) .ne. ngvecs ) then
          ierr = -2
          write(6,*) (2*test_gvec-1), ngvecs
          return
        endif
      else
        if( test_gvec .ne. ngvecs ) then
          ierr = -2
          write(6,*) test_gvec, ngvecs
          return
        endif
      endif


      ! Error synch. Also ensures that the other procs have posted their recvs
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 ) return
      if( ierr_ .ne. 0 ) then
        ierr = ierr_
        return
      endif


      if( ioWorkaround ) then
#ifdef TRYMPI
        offset = offset + 2 * 4 + 9 * 8
        call MPI_FILE_READ_AT( fh, offset, gvecs, 3 * test_gvec, MPI_INTEGER, MPI_STATUS_IGNORE, ierr )
        if( ierr .ne. 0 ) return
        ! 12 = 3 * 4
        offset = offset + int( test_gvec * 12, MPI_OFFSET_KIND )
#else
        allocate( dread( 9 ) )
        read( 99 ) crap, dread(:), crap
        deallocate( dread )
        read( 99 ) crap, gvecs( :, 1:test_gvec )! , crap
        ! delay reading the record end statement to reduce number of read calls
#endif
      else
        read(99)
        ! Using test_gvec for gamma support
        read( 99 ) gvecs( :, 1:test_gvec )
      endif

      maxBands = qe62_getAllBandsForPoolID( 0 )
      do id = 1, pool_nproc - 1
        maxBands = max( maxBands, qe62_getAllBandsForPoolID( id ) )
      enddo
      !
      ! no more than 8GB @ 16Byte/complex
!      bufferSize = floor( 36870912.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
      bufferSize = floor( 536870912.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
!      bufferSize = floor( 1073741824.0_DP /  ( real( test_gvec, DP ) * real( maxBands, DP ) ) )
      bufferSize = min( bufferSize, pool_nproc - 1 )
      bufferSize = max( bufferSize, 1 )
      allocate( cmplx_wvfn( test_gvec, maxBands, bufferSize ) )

!      nr = pool_nproc 
      nr = bufferSize
!      nr = 2 * pool_nproc
      allocate( requests( 0:nr ) )
      requests(:) = MPI_REQUEST_NULL
#ifdef MPI
      call MPI_IBCAST( gvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 0 ), ierr )
#endif

      write(1000+myid,*) '***Reading k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', ngvecs
      write(1000+myid,*) '   Nbands: ', nbands
      write(1000+myid,*) '   Nbuffer:', bufferSize


      ! if we are skipping bands, do that here
!      do i = 1, bands(1)-1
!        read( 99 ) crap, cmplx_wvfn( 1, 1 )
!      enddo

      ! Keep the reads under 4MB chunks 
      !  on test cluster 4MB seems to trigger some double buffering or something
      !  should move to MPI READ calls instead of fortran
      if( test_gvec .gt. dblBufSize ) then
        ! 
        doubleBufferLoop = (test_gvec-1) / dblBufSize
      else
        doubleBufferLoop = 0
      endif
      doubleBufferLoop = 0

      write(1000+myid,*) '   DBLbuf: ', doubleBufferLoop, ioworkaround


      start_band = 1

#ifdef MPI
      ! loop over each proc in this pool to send wavefunctions
      do id = 0, pool_nproc - 1
        nbands_to_send = qe62_getAllBandsForPoolID( id )

        ! If mine, read directly to wvfn
        if( id .eq. pool_myid ) then
          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
#if 0
            igb = 1
            jgb = dblBufsize
            do gb = 1, doubleBufferLoop
              read( 99 ) wfns( igb : jgb, i )
              igb = igb + dblBufsize
              jgb = jgb + dblBufsize
            enddo
!            read( 99 ) wfns( 1:test_gvec, i )
            read( 99 ) wfns( igb:test_gvec, i )
#else 
#if 0
            do gb = 1, test_gvec, dblBufsize
              jgb = min( gb + dblBufSize - 1, test_gvec )
              read( 99 ) wfns( gb : jgb, i )
            enddo
#else
            if( ioWorkaround ) then
#ifdef TRYMPI
              offset = offset + 2 * 4
              call MPI_FILE_READ_AT( fh, offset, wfns(:,i), test_gvec, MPI_DOUBLE_COMPLEX, MPI_STATUS_IGNORE, ierr )
              if( ierr .ne. 0 ) return
              offset = offset + int( test_gvec * 16, MPI_OFFSET_KIND )
#else
              read( 99 ) crap, crap
              do gb = 1, test_gvec, dblBufsize
                jgb = min( gb + dblBufSize - 1, test_gvec )
                read( 99 ) wfns( gb : jgb, i )
              enddo
!              read( 99 ) crap
!              read( 99 ) crap, wfns( 1:test_gvec, i ), crap
#endif
            else
              read( 99 ) wfns( 1:test_gvec, i )
            endif
#endif
#endif  
          enddo
          call SCREEN_tk_stop("dft-read")
        
        ! IF not mine, find open buffer, read to buffer, send buffer
        else
          j = 0
          do i = 1, bufferSize
            if( requests( i ) .eq. MPI_REQUEST_NULL ) then
              j = i
              exit
            endif
          enddo
          if( j .eq. 0 ) then
            call MPI_WAITANY( bufferSize, requests(1:bufferSize), j, MPI_STATUS_IGNORE, ierr )
            write(1000+myid, * ) 'Waited for buffer:', j
            if( j .eq. MPI_UNDEFINED ) j = 1
          endif
          

          call SCREEN_tk_start("dft-read")
          do i = 1, nbands_to_send
#if 0
            igb = 1
            jgb = dblBufsize
            do gb = 1, doubleBufferLoop
              read( 99 ) cmplx_wvfn( igb : jgb, i, j )
              igb = igb + dblBufsize
              jgb = jgb + dblBufsize
            enddo
            read( 99 ) cmplx_wvfn( igb : test_gvec, i, j )
!            read( 99 ) cmplx_wvfn( 1:test_gvec, i, j )
#else
#if 0
            do gb = 1, test_gvec, dblBufsize
              jgb = min( gb + dblBufSize - 1, test_gvec )
              read( 99 ) cmplx_wvfn( gb : jgb, i, j )
            enddo
#else
            if( ioWorkaround ) then
#ifdef TRYMPI
              offset = offset + 2 * 4
              call MPI_FILE_READ_AT( fh, offset, cmplx_wvfn(:,i,j), test_gvec, MPI_DOUBLE_COMPLEX, &
                                     MPI_STATUS_IGNORE, ierr )
              if( ierr .ne. 0 ) return
              offset = offset + int( test_gvec * 16, MPI_OFFSET_KIND )
#else
              read( 99 ) crap, crap
              do gb = 1, test_gvec, dblBufsize
                jgb = min( gb + dblBufSize - 1, test_gvec )
                read( 99 ) cmplx_wvfn( gb : jgb, i, j )
              enddo
!              read( 99 ) crap
!              read( 99 ) crap, cmplx_wvfn( 1:test_gvec, i, j ), crap
#endif
            else
              read( 99 ) cmplx_wvfn( 1:test_gvec, i, j )
            endif
#endif
#endif
          enddo
          call SCREEN_tk_stop("dft-read")

          write(1000+myid,'(A,3(1X,I8))') '   Sending ...', id, start_band, nbands_to_send
          call MPI_IRSEND( cmplx_wvfn( 1, 1, j ), nbands_to_send*test_gvec, MPI_DOUBLE_COMPLEX, &
                         id, 1, pool_comm, requests( j ), ierr )
          if( ierr .ne. 0 ) return
      
        endif

#if 0
        !TODO
        ! Use MPI_TYPE or VECTOR to only send the first test_gvec 
        ! For now, no worries
        ! don't send if I am me
        if( id .ne. pool_myid ) then
          write(1000+myid,'(A,3(1X,I8))') '   Sending ...', id, start_band, nbands_to_send
          call MPI_IRSEND( cmplx_wvfn( 1, start_band ), nbands_to_send*test_gvec, MPI_DOUBLE_COMPLEX, &
                         id, 1, pool_comm, requests( id ), ierr )
          ! this might not sync up
          if( ierr .ne. 0 ) return
        else
          write(1000+myid,'(A,3(1X,I8))') "   Don't Send: ", start_band, nbands_to_send, my_bands
          wfns( 1:test_gvec, : ) = cmplx_wvfn( 1:test_gvec, start_band : nbands_to_send + start_band - 1 )
        endif
#endif

        start_band = start_band + nbands_to_send
      enddo
#endif

      if( ioworkaround ) then
#ifndef TRYMPI
      close( 99 )
#endif
      else
        close( 99 )
      endif
      

      nr=nr+1
    else
      nr = 2
      allocate( requests( nr ), cmplx_wvfn(1,1,1) )
      requests(:) = MPI_REQUEST_NULL
      write(1000+myid,*) '***Receiving k-point: ', ikpt, ispin
      write(1000+myid,*) '   Ngvecs: ', ngvecs
      write(1000+myid,*) '   Nbands: ', nbands

      if( gammaFullStorage .and. is_gamma ) then
        test_gvec = ( ngvecs + 1 ) / 2
      else
        test_gvec = ngvecs 
      endif

      write(1000+myid,*) '   Ngvecs: ', test_gvec
      write(1000+myid,*) '   Gamma : ', is_gamma

#ifdef MPI
      call MPI_TYPE_VECTOR( my_bands, test_gvec, ngvecs, MPI_DOUBLE_COMPLEX, newType, ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_COMMIT( newType, ierr )
      if( ierr .ne. 0 ) return


      call MPI_IRECV( wfns, 1, newType, pool_root, 1, pool_comm, requests( 1 ), ierr )
      if( ierr .ne. 0 ) return
      call MPI_TYPE_FREE( newType, ierr )
      if( ierr .ne. 0 ) return

      call MPI_IBCAST( gvecs, 3*test_gvec, MPI_INTEGER, pool_root, pool_comm, requests( 2 ), ierr )
      call MPI_BCAST( ierr, 1, MPI_INTEGER, pool_root, pool_comm, ierr_ )
      if( ierr .ne. 0 .or. ierr_ .ne. 0 ) then
        call MPI_CANCEL( requests( 1 ) , ierr )
        call MPI_CANCEL( requests( 2 ) , ierr )
        ierr = 5
        return
      endif

#endif


    endif


    call MPI_WAITALL( nr, requests, MPI_STATUSES_IGNORE, ierr )
    if( ierr .ne. 0 ) return

    deallocate( cmplx_wvfn, requests )

    if( gammaFullStorage .and. is_gamma ) then
      j = test_gvec
      do i = 1, test_gvec
        if( gvecs(1,i) .eq. 0 .and. gvecs(2,i) .eq. 0 .and. gvecs(3,i) .eq. 0 ) then
          k = i + 1
          exit
        endif
        j = j + 1
        gvecs(:,j) = -gvecs(:,i)
        wfns(j,:) = conjg( wfns(i,:) )
      enddo

      do i = k, test_gvec
        j = j + 1
        gvecs(:,j) = -gvecs(:,i)
        wfns(j,:) = conjg( wfns(i,:) )
      enddo
    endif

    write(1000+myid,*) '***Finishing k-point: ', ikpt, ispin
    call MPI_BARRIER( pool_comm, ierr )

  end subroutine qe62_read_at_kpt



end module ocean_qe62_files
