!*****************************************************************************************
    module pikaia_module
!*****************************************************************************************
!****h* PIKAIA/pikaia_module
!
!  NAME
!    pikaia_module
!
!  DESCRIPTION
!    PIKAIA is a general purpose unconstrained optimization
!    method based on a genetic algorithm.
!    This is an object-oriented version of the algorithm for Fortran 2003/2008.
!
!  SEE ALSO
!    * http://www.hao.ucar.edu/modeling/pikaia/pikaia.php [description page]
!    * http://download.hao.ucar.edu/archive/pikaia/ [original sourcecode]
!
!  HISTORY
!    * Jacob Williams : 3/8/2015 : Significant refactoring of original PIKAIA code.
!      Converted to free-form source, double precision real variables, added various
!      new features, and an object-oriented interface.
!
!*****************************************************************************************

    use,intrinsic :: iso_fortran_env

    implicit none

    private

    !*********************************************************
    !****d* pikaia_module/wp
    !
    !  NAME
    !    wp
    !
    !  DESCRIPTION
    !    Default real kind [8 bytes].
    !
    !  SOURCE
    integer,parameter :: wp = real64
    !*********************************************************

    !*********************************************************
    !****c* pikaia_module/pikaia_class
    !
    !  NAME
    !    pikaia_class
    !
    !  DESCRIPTION
    !    Main class for using the Pikaia algorithm.
    !    INIT and SOLVE are the only public methods.
    !
    !  SOURCE
    type,public :: pikaia_class

        private

        integer :: n = 0  !number of solution variables
        real(wp),dimension(:),allocatable :: xu, xl    !lower,upper bounds on x
        real(wp),dimension(:),allocatable :: del       !internal variables

        !other solution inputs (with default values):
        integer  :: np                 = 100
        integer  :: ngen               = 500
        integer  :: nd                 = 5
        real(wp) :: pcross             = 0.85_wp
        integer  :: imut               = 2
        real(wp) :: pmut               = 0.005_wp
        real(wp) :: pmutmn             = 0.0005_wp
        real(wp) :: pmutmx             = 0.25_wp
        real(wp) :: fdif               = 1.0_wp
        integer  :: irep               = 1
        integer  :: ielite             = 1
        integer  :: ivrb               = 0
        real(wp) :: convergence_tol    = 0.0001_wp
        integer  :: convergence_window = 20
        integer  :: iseed              = 999

        !used internally:
        real(wp) :: bestft = huge(1.0_wp)
        real(wp) :: pmutpv = huge(1.0_wp)

        !user-supplied procedures:
        procedure(pikaia_func),pointer :: user_f => null()    !fitness function
        procedure(iter_func),pointer   :: iter_f => null()    !reporting function

    contains

        !public routines:
        procedure,non_overridable,public :: init   => set_inputs
        procedure,non_overridable,public :: solve  => solve_with_pikaia

        !private routines:
        procedure,non_overridable :: ff  => func_wrapper  !internal pikaia function (x:[0,1])
        procedure,non_overridable :: newpop,stdrep,genrep,&
                                     adjmut,cross,encode,&
                                     mutate,decode,select_parent,&
                                     report,rnkpop

    end type pikaia_class
    !*********************************************************

    !*********************************************************
    !****I* pikaia_module/pikaia_func
    !
    !  NAME
    !    pikaia_func
    !
    !  DESCRIPTION
    !    The interface for the function that pikaia will be maximizing:
    !
    !  SOURCE
    abstract interface
        subroutine pikaia_func(me,x,f)
        import :: wp,pikaia_class
        implicit none
        class(pikaia_class),intent(inout)  :: me    !pikaia class
        real(wp),dimension(:),intent(in)   :: x     !optimization variable vector
        real(wp),intent(out)               :: f     !fitness value
        end subroutine pikaia_func
    end interface
    !*********************************************************

    !*********************************************************
    !****I* pikaia_module/iter_func
    !
    !  NAME
    !    iter_func
    !
    !  DESCRIPTION
    !    The interface for the function that user can specify
    !    to report each iteration when pikaia is running.
    !
    !  SOURCE
    abstract interface
        subroutine iter_func(me,iter,x,f)
        import :: wp,pikaia_class
        implicit none
        class(pikaia_class),intent(inout)  :: me    !pikaia class
        integer,intent(in)                 :: iter  !iteration number
        real(wp),dimension(:),intent(in)   :: x     !optimization variable vector
        real(wp),intent(in)                :: f     !fitness value
        end subroutine iter_func
    end interface
    !*********************************************************

    contains
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/set_inputs
!
!  NAME
!    set_inputs
!
!  DESCRIPTION
!    Set the inputs to the pikaia class.
!    The routine must be called before the solve routine can be used.
!
!  INPUTS
!    The following inputs are required:
!    * n - is the parameter space dimension, i.e., the number
!      of adjustable parameters (size of the x vector).
!    * f - is a user-supplied scalar function of n variables,
!      which must have the pikaia_func procedure interface.
!      By convention, f should return higher values for more optimal
!      parameter values (i.e., individuals which are more "fit").
!      For example, in fitting a function through data points, f
!      could return the inverse of chi**2.
!    * xl - vector of lower bounds for x
!    * xu - vector of upper bounds for x
!
!    For the following parameters, if they are not present, then
!    the default values in the class are used:
!    * iter_f - user-supplied subroutine that will report each iteration.
!      It must have the iter_func procedure interface.  If not present,
!      then it is not used.  (note: this is independent of ivrb).
!    * np - number of individuals in a population (default
!      is 100)
!    * ngen - maximum number of iterations
!    * nd - number of significant digits (i.e., number of
!               genes) retained in chromosomal encoding (default
!               is 6).
!    * pcross - crossover probability; must be  <= 1.0 (default
!               is 0.85). If crossover takes place, either one
!               or two splicing points are used, with equal
!               probabilities
!    * imut - mutation mode; 1/2/3/4/5 (default is 2).
!               1=one-point mutation, fixed rate.
!               2=one-point, adjustable rate based on fitness.
!               3=one-point, adjustable rate based on distance.
!               4=one-point+creep, fixed rate.
!               5=one-point+creep, adjustable rate based on fitness.
!               6=one-point+creep, adjustable rate based on distance.
!    * pmut - initial mutation rate; should be small (default
!               is 0.005) (Note: the mutation rate is the probability
!               that any one gene locus will mutate in
!               any one generation.)
!    * pmutmn - minimum mutation rate; must be >= 0.0 (default is 0.0005)
!    * pmutmx - maximum mutation rate; must be <= 1.0 (default is 0.25)
!    * fdif - relative fitness differential; range from 0
!               (none) to 1 (maximum).  (default is 1.0)
!    * irep - reproduction plan; 1/2/3=Full generational
!               replacement/Steady-state-replace-random/Steady-
!               state-replace-worst (default is 3)
!    * ielite - elitism flag; 0/1=off/on (default is 0)
!               (Applies only to reproduction plans 1 and 2)
!    * ivrb - printed output 0/1/2=None/Minimal/Verbose
!               (default is 0)
!    * convergence_tol - convergence tolerance; must be > 0.0
!               (default is 0.0001)
!    * convergence_window - convergence window; must be >= 0
!                 This is the number of consecutive solutions
!                 within the tolerance for convergence to
!                 be declared (default is 20)
!    * iseed - random seed value; must be > 0 (default is 999)
!
!  OUTPUT
!    * status - Will be 0 if there were no errors.
!
!  AUTHOR
!    Jacob Williams (based on setctl in original code).
!
!  SOURCE

    subroutine set_inputs(me,&
                            n,xl,xu,f,status,&
                            iter_f,&
                            np,ngen,nd,pcross,pmutmn,pmutmx,pmut,imut,&
                            fdif,irep,ielite,ivrb,&
                            convergence_tol,convergence_window,iseed)

    implicit none

    class(pikaia_class),intent(inout)  :: me        !pikaia class
    integer,intent(in)                 :: n         !number of variables (size of x)
    real(wp),dimension(n),intent(in)   :: xl        !lower bound
    real(wp),dimension(n),intent(in)   :: xu        !upper bound
    procedure(pikaia_func)             :: f         !user fitness function
    procedure(iter_func),optional      :: iter_f    !iteration report function
    integer,intent(out)                :: status    !status flag (0 if OK)
    integer,intent(in),optional        :: np
    integer,intent(in),optional        :: ngen
    integer,intent(in),optional        :: nd
    integer,intent(in),optional        :: imut
    integer,intent(in),optional        :: irep
    integer,intent(in),optional        :: ielite
    integer,intent(in),optional        :: ivrb
    integer,intent(in),optional        :: convergence_window
    integer,intent(in),optional        :: iseed
    real(wp),intent(in),optional       :: pcross
    real(wp),intent(in),optional       :: pmutmn
    real(wp),intent(in),optional       :: pmutmx
    real(wp),intent(in),optional       :: pmut
    real(wp),intent(in),optional       :: fdif
    real(wp),intent(in),optional       :: convergence_tol

    me%n = n

    if (allocated(me%xl)) deallocate(me%xl)
    allocate(me%xl(n))
    me%xl = xl

    if (allocated(me%xu)) deallocate(me%xu)
    allocate(me%xu(n))
    me%xu = xu

    if (allocated(me%del)) deallocate(me%del)
    allocate(me%del(n))
    me%del = me%xu - me%xl

    me%user_f => f

    if (present(iter_f)) me%iter_f => iter_f

    if (present(np                 )) me%np                 = np
    if (present(ngen               )) me%ngen               = ngen
    if (present(nd                 )) me%nd                 = nd
    if (present(pcross             )) me%pcross             = pcross
    if (present(imut               )) me%imut               = imut
    if (present(pmut               )) me%pmut               = pmut
    if (present(pmutmn             )) me%pmutmn             = pmutmn
    if (present(pmutmx             )) me%pmutmx             = pmutmx
    if (present(fdif               )) me%fdif               = fdif
    if (present(irep               )) me%irep               = irep
    if (present(ielite             )) me%ielite             = ielite
    if (present(ivrb               )) me%ivrb               = ivrb
    if (present(convergence_tol    )) me%convergence_tol    = convergence_tol
    if (present(convergence_window )) me%convergence_window = convergence_window
    if (present(iseed              )) me%iseed              = iseed

    !check for errors:

    !initialize error flag:
    status = 0

    !Print a header
    if (me%ivrb>0) then
        write(output_unit,'(A)') '------------------------------------------------------------'
        write(output_unit,'(A)') '              PIKAIA Genetic Algorithm Report               '
        write(output_unit,'(A)') '------------------------------------------------------------'
        write(output_unit,'(A,I4)')    ' Number of Generations evolving: ',me%ngen
        write(output_unit,'(A,I4)')    '     Individuals per generation: ',me%np
        write(output_unit,'(A,I4)')    '  Number of Chromosome segments: ',me%n
        write(output_unit,'(A,I4)')    '  Length of Chromosome segments: ',me%nd
        write(output_unit,'(A,E10.4)') '          Crossover probability: ',me%pcross
        write(output_unit,'(A,E10.4)') '          Initial mutation rate: ',me%pmut
        write(output_unit,'(A,E10.4)') '          Minimum mutation rate: ',me%pmutmn
        write(output_unit,'(A,E10.4)') '          Maximum mutation rate: ',me%pmutmx
        write(output_unit,'(A,E10.4)') '  Relative fitness differential: ',me%fdif
        write(output_unit,'(A,E10.4)') '          Convergence tolerance: ',me%convergence_tol
        write(output_unit,'(A,I4)')    '             Convergence window: ',me%convergence_window
        select case (me%imut)
        case(1); write(output_unit,'(A)') '                  Mutation Mode: Uniform, Constant Rate'
        case(2); write(output_unit,'(A)') '                  Mutation Mode: Uniform, Variable Rate (F)'
        case(3); write(output_unit,'(A)') '                  Mutation Mode: Uniform, Variable Rate (D)'
        case(4); write(output_unit,'(A)') '                  Mutation Mode: Uniform+Creep, Constant Rate'
        case(5); write(output_unit,'(A)') '                  Mutation Mode: Uniform+Creep, Variable Rate (F)'
        case(6); write(output_unit,'(A)') '                  Mutation Mode: Uniform+Creep, Variable Rate (D)'
        end select
        select case (me%irep)
        case(1); write(output_unit,'(A)') '              Reproduction Plan: Full generational replacement'
        case(2); write(output_unit,'(A)') '              Reproduction Plan: Steady-state-replace-random'
        case(3); write(output_unit,'(A)') '              Reproduction Plan: Steady-state-replace-worst'
        end select
        write(output_unit,'(A)') '------------------------------------------------------------'
    end if

    !Check some control values
    if (me%imut/=1 .and. me%imut/=2 .and. me%imut/=3 .and. &
          me%imut/=4 .and. me%imut/=5 .and. me%imut/=6) then
       write(output_unit,'(A)') ' ERROR: illegal value for Mutation Mode.'
       status = 5
    end if

    if (me%fdif>1.0_wp) then
       write(output_unit,'(A)') ' ERROR: illegal value for Relative fitness differential.'
       status = 9
    end if

    if (me%irep/=1 .and. me%irep/=2 .and. me%irep/=3) then
       write(output_unit,'(A)') ' ERROR: illegal value for Reproduction plan.'
       status = 10
    end if

    if (me%pcross>1.0_wp .or. me%pcross<0.0_wp) then
       write(output_unit,'(A)') ' ERROR: illegal value for Crossover probability.'
       status = 4
    end if

    if (me%ielite/=0 .and. me%ielite/=1) then
       write(output_unit,'(A)') ' ERROR: illegal value for Elitism flag.'
       status = 11
    end if

   if (me%convergence_tol<=0.0_wp) then
       write(output_unit,'(A)') ' ERROR: illegal value for Convergence tolerance.'
       status = 101
   end if

   if (me%convergence_window<=0) then
       write(output_unit,'(A)') ' ERROR: illegal value for Convergence window.'
       status = 102
   end if

   if (me%iseed<=0) then
       write(output_unit,'(A)') ' ERROR: illegal value for iseed.'
       status = 103
   end if

   if (me%nd>9 .or. me%nd<1) then
       write(output_unit,'(A)') ' ERROR: illegal value for Chromosome length.'
       status = 104
   end if

   if (mod(me%np,2)>0) then
      write(output_unit,'(A)') ' ERROR: population size must be an even number.'
      status = 105
   end if

   if (me%irep==1 .and. me%imut==1 .and. me%pmut>0.5_wp .and. me%ielite==0) then
      write(output_unit,'(A)') &
       ' WARNING: dangerously high value for Initial mutation rate; '//&
       '(Should enforce elitism with ielite=1.)'
   end if

   if (me%irep==1 .and. me%imut==2 .and. me%pmutmx>0.5_wp .and. me%ielite==0) then
      write(output_unit,'(A)') &
      ' WARNING: dangerously high value for Maximum mutation rate; '//&
      '(Should enforce elitism with ielite=1.)'
   end if

   if (me%fdif<0.33_wp .and. me%irep/=3) then
      write(output_unit,'(A)') &
      ' WARNING: dangerously low value of Relative fitness differential.'
   end if

    end subroutine set_inputs
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/pikaia
!
!  NAME
!    pikaia
!
!  DESCRIPTION
!    Optimization (maximization) of user-supplied "fitness" function
!    over n-dimensional parameter space x using a basic genetic
!    algorithm method.
!
!    Genetic algorithms are heuristic search techniques that
!    incorporate in a computational setting, the biological notion
!    of evolution by means of natural selection.  This subroutine
!    implements the three basic operations of selection, crossover,
!    and mutation, operating on "genotypes" encoded as strings.
!
!    Version 1.2 differs from version 1.0 (December 1995) in that
!    it includes (1) two-point crossover, (2) creep mutation, and
!    (3) dynamical adjustment of the mutation rate based on metric
!    distance in parameter space.
!
!  INPUT
!    * x - initial guess for solution vector
!
!  OUTPUTS
!    * x - the "fittest" (optimal) solution found,
!      i.e., the solution which maximizes the fitness function
!    * f - is the (scalar) value of the fitness function at x
!    * status - an indicator of the success or failure
!      of the call to pikaia (0=success; non-zero=failure)
!
!  AUTHOR
!    * Paul Charbonneau & Barry Knapp
!      (High Altitude Observatory, National Center for Atmospheric Research)
!
!  SEE ALSO
!    * Charbonneau, Paul. "An introduction to gemetic algorithms for
!        numerical optimization", NCAR Technical Note TN-450+IA
!        (April 2002)
!    * Charbonneau, Paul. "Release Notes for PIKAIA 1.2",
!        NCAR Technical Note TN-451+STR (April 2002)
!    * Charbonneau, Paul, and Knapp, Barry. "A User's Guide
!        to PIKAIA 1.0" NCAR Technical Note TN-418+IA
!        (December 1995)
!    * Goldberg, David E.  Genetic Algorithms in Search, Optimization,
!        & Machine Learning.  Addison-Wesley, 1989.
!    * Davis, Lawrence, ed.  Handbook of Genetic Algorithms.
!        Van Nostrand Reinhold, 1991.
!
!  HISTORY
!    * Version 1.2 [ 2002 April 3 ]
!    * Jacob Williams : 3/8/3015 : Refactoring and some new features.
!
!  SOURCE

    subroutine pikaia(me,x,f,status)

    implicit none

    !subroutine arguments:
    class(pikaia_class),intent(inout)      :: me
    real(wp),dimension(:),intent(inout)    :: x
    real(wp),intent(out)                   :: f
    integer,intent(out)                    :: status

    !Local variables
    integer  :: k,ip,ig,ip1,ip2,new,newtot
    integer  :: i_window
    real(wp) :: current_best_f, last_best_f
    logical  :: convergence
    real(wp),dimension(:,:),allocatable :: ph, oldph, newph
    integer,dimension(:),allocatable    :: gn1, gn2
    integer,dimension(:),allocatable    :: ifit, jfit
    real(wp),dimension(:),allocatable   :: fitns

    real(wp),parameter :: big = huge(1.0_wp)    !a large number

    !initialize:
    call random_init(me%iseed)
    me%bestft   = -big
    me%pmutpv   = -big
    i_window    = 0
    last_best_f = -big
    convergence = .false.
    status = 0

    !allocate the arrays:
    allocate(ph    (me%n,2))
    allocate(oldph (me%n,me%np))
    allocate(newph (me%n,me%np))
    allocate(gn1   (me%n*me%nd))
    allocate(gn2   (me%n*me%nd))
    allocate(ifit  (me%np))
    allocate(jfit  (me%np))
    allocate(fitns (me%np))

    !JW: the first element of the population is the initial guess:
    oldph(:,1) = x
    do k=1,me%n    !make sure they are all within the bounds !
        if (oldph(k,1)<0.0_wp) then
            oldph(k,1)=0.0_wp
        elseif (oldph(k,1)>1.0_wp) then
            oldph(k,1)=1.0_wp
        end if
    end do
    call me%ff(oldph(:,1),fitns(1))

    !Compute initial (random but bounded) phenotypes
    do ip=2,me%np
        do k=1,me%n
            oldph(k,ip)=urand()
        end do
        call me%ff(oldph(:,ip),fitns(ip))
    end do

    !Rank initial population by fitness order
    call me%rnkpop(fitns,ifit,jfit)

    !Main Generation Loop
    do ig=1,me%ngen

        !Main Population Loop
        newtot=0
        do ip=1,me%np/2

            !1. pick two parents
            call me%select_parent(jfit,ip1)
            do
                call me%select_parent(jfit,ip2)
                if (ip1/=ip2) exit
            end do

            !2. encode parent phenotypes
            call me%encode(oldph(:,ip1),gn1)
            call me%encode(oldph(:,ip2),gn2)

            !3. breed
            call me%cross(gn1,gn2)
            call me%mutate(gn1)
            call me%mutate(gn2)

            !4. decode offspring genotypes
            call me%decode(gn1,ph(:,1))
            call me%decode(gn2,ph(:,2))

            !5. insert into population
            if (me%irep==1) then
                call me%genrep(ip,ph,newph)
            else
                call me%stdrep(ph,oldph,fitns,ifit,jfit,new)
                newtot = newtot+new
            end if

        end do    !End of Main Population Loop

        !if running full generational replacement: swap populations
        if (me%irep==1) call me%newpop(oldph,newph,ifit,jfit,fitns,newtot)

        !adjust mutation rate?
        if (me%imut==2 .or. me%imut==3 .or. me%imut==5 .or. me%imut==6) &
            call adjmut(me,oldph,fitns,ifit)

        !report this iteration:
        if (me%ivrb>0) call me%report(oldph,fitns,ifit,ig,newtot)
        if (associated(me%iter_f)) call me%iter_f(ig,oldph(1:me%n,ifit(me%np)),fitns(ifit(me%np)))

        !JW additions: add a convergence criteria
        ! [stop if the last convergence_window iterations are all within the convergence_tol]
        current_best_f = fitns(ifit(me%np))    !current iteration best fitness
        if (abs(current_best_f-last_best_f)<=me%convergence_tol) then
            !this solution is within the tol from the previous one
            i_window = i_window + 1    !number of solutions within the convergence tolerance
        else
            i_window = 0    !a significantly better solution was found, reset window
        end if
        if (i_window>=me%convergence_window) then
            convergence = .true.
            exit !exit main loop -> convergence
        end if
        last_best_f = current_best_f    !to compare with next iteration

    end do    !End of Main Generation Loop

    !JW additions:
    if (me%ivrb>0) then
        if (convergence) then
            write(output_unit,'(A)') 'Solution Converged'
        else
            write(output_unit,'(A)') 'Iteration Limit Reached'
        end if
    end if

    !Return best phenotype and its fitness
    x = oldph(1:me%n,ifit(me%np))
    f = fitns(ifit(me%np))

    !clean up:
    deallocate(ph)
    deallocate(oldph)
    deallocate(newph)
    deallocate(gn1)
    deallocate(gn2)
    deallocate(ifit)
    deallocate(jfit)
    deallocate(fitns)

    end subroutine pikaia
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/solve_with_pikaia
!
!  NAME
!    solve_with_pikaia
!
!  DESCRIPTION
!    Main pikaia wrapper used by the class.
!
!  AUTHOR
!    Jacob Williams
!
!  SOURCE

    subroutine solve_with_pikaia(me,x,f,status)

    implicit none

    class(pikaia_class),intent(inout)   :: me
    real(wp),dimension(:),intent(inout) :: x
    real(wp),intent(out)                :: f
    integer,intent(out)                 :: status

    !scale input initial guess to be [0,1]:
    x = (x-me%xl)/me%del

    !call the main routine, using the wrapper function:
    call pikaia(me,x,f,status)

    !unscale output to be [xl,xu]:
    x = me%xl + me%del*x

    end subroutine solve_with_pikaia
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/func_wrapper
!
!  NAME
!    solve_with_pikaia
!
!  DESCRIPTION
!    Wrapper for the user's function that is used by the main pikaia routine
!    The x input to this function comes from pikaia, and will be between [0,1].
!
!  AUTHOR
!    Jacob Williams
!
!  SOURCE

    subroutine func_wrapper(me,x,f)

    implicit none

    class(pikaia_class),intent(inout) :: me   ! pikaia class
    real(wp),dimension(:),intent(in)  :: x    ! optimization variable vector [0,1]
    real(wp),intent(out)              :: f    ! fitness value

    real(wp),dimension(me%n) :: xp    !unscaled x vector: [xu,xl]

    !map each x variable from [0,1] to [xl,xu]:
    xp = me%xl + me%del*x

    !call the user's function with xp:
    call me%user_f(xp,f)

    end subroutine func_wrapper
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/urand
!
!  NAME
!    urand
!
!  DESCRIPTION
!    Return the next pseudo-random deviate from a sequence which is
!    uniformly distributed in the interval [0,1]
!
!   This is now just a wrapper for the intrinsic random_number function.
!
!  AUTHOR
!    Jacob Williams, 3/8/2015
!
!  SOURCE

    function urand() result(r)

    implicit none

    real(wp) :: r

    call random_number(r)

    end function urand
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/rqsort
!
!  NAME
!    rqsort
!
!  DESCRIPTION
!    Return integer array p which indexes array a in increasing order.
!    Array a is not disturbed.  The Quicksort algorithm is used.
!
!  SEE ALSO
!    * N. Wirth, "Algorithms and Data Structures", Prentice-Hall, 1986
!
!  AUTHOR
!    B. G. Knapp, 86/12/23
!
!  SOURCE

    subroutine rqsort(n,a,p)

    implicit none

    integer,intent(in)               :: n
    real(wp),dimension(n),intent(in) :: a
    integer,dimension(n),intent(out) :: p

    !Constants
    integer,parameter :: LGN = 32      ! log base 2 of maximum n
    integer,parameter :: Q   = 11      ! smallest subfile to use quicksort on

    !Local:
    real(wp) :: x
    integer,dimension(LGN)    :: stackl,stackr
    integer :: s,t,l,m,r,i,j

    !Initialize the stack
      stackl(1)=1
      stackr(1)=n
      s=1

    !Initialize the pointer array
      do i=1,n
         p(i)=i
      end do

    2 if (s>0) then
         l=stackl(s)
         r=stackr(s)
         s=s-1

    3    if ((r-l)<Q) then

        !Use straight insertion
            do i=l+1,r
               t = p(i)
               x = a(t)
               do j=i-1,l,-1
                  if (a(p(j))<=x) goto 5
                  p(j+1) = p(j)
               end do
               j=l-1
    5          p(j+1) = t
            end do
         else

        !Use quicksort, with pivot as median of a(l), a(m), a(r)
            m=(l+r)/2
            t=p(m)
            if (a(t)<a(p(l))) then
               p(m)=p(l)
               p(l)=t
               t=p(m)
            end if
            if (a(t)>a(p(r))) then
               p(m)=p(r)
               p(r)=t
               t=p(m)
               if (a(t)<a(p(l))) then
                  p(m)=p(l)
                  p(l)=t
                  t=p(m)
               end if
            end if

        !Partition
            x=a(t)
            i=l+1
            j=r-1
    7       if (i<=j) then
    8          if (a(p(i))<x) then
                  i=i+1
                  goto 8
               end if
    9          if (x<a(p(j))) then
                  j=j-1
                  goto 9
               end if
               if (i<=j) then
                  t=p(i)
                  p(i)=p(j)
                  p(j)=t
                  i=i+1
                  j=j-1
               end if
               goto 7
            end if

        !Stack the larger subfile
            s=s+1
            if ((j-l)>(r-i)) then
               stackl(s)=l
               stackr(s)=j
               l=i
            else
               stackl(s)=i
               stackr(s)=r
               r=j
            end if
            goto 3
         end if
         goto 2
      end if

    end subroutine rqsort
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/random_init
!
!  NAME
!    random_init
!
!  DESCRIPTION
!    Initialize the random number generator with the input seed value.
!
!  AUTHOR
!    Jacob Williams, 3/8/2015
!
!  SOURCE

    subroutine random_init(iseed)

    implicit none

    integer,intent(in) :: iseed

    integer,dimension(:),allocatable :: seed
    integer :: n

    call random_seed(size=n)
    allocate(seed(n))
    seed = iseed
    call random_seed(put=seed)
    deallocate(seed)

    end subroutine random_init
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/report
!
!  NAME
!    report
!
!  DESCRIPTION
!    Write generation report to standard output
!
!  SOURCE

    subroutine report(me,oldph,fitns,ifit,ig,nnew)

    implicit none

    class(pikaia_class),intent(inout)         :: me
    real(wp),dimension(me%n,me%np),intent(in) :: oldph
    real(wp),dimension(me%np),intent(in)      :: fitns
    integer,dimension(me%np),intent(in)       :: ifit
    integer,intent(in)                        :: ig
    integer,intent(in)                        :: nnew

    integer :: ndpwr,k
    logical :: rpt

    rpt=.false.

    if (me%pmut/=me%pmutpv) then
       me%pmutpv=me%pmut
       rpt=.true.
    end if

    if (fitns(ifit(me%np))/=me%bestft) then
       me%bestft=fitns(ifit(me%np))
       rpt=.true.
    end if

    if (rpt .or. me%ivrb>=2) then

        !Power of 10 to make integer genotypes for display
        ndpwr = nint(10.0_wp**me%nd)

        write(output_unit,'(/I6,I6,F10.6,4F10.6)') &
            ig,nnew,me%pmut,fitns(ifit(me%np)),&
            fitns(ifit(me%np-1)),fitns(ifit(me%np/2))

        do k=1,me%n
            write(output_unit,'(22X,3I10)') &
                    nint(ndpwr*oldph(k,ifit(me%np))),&
                    nint(ndpwr*oldph(k,ifit(me%np-1))),&
                    nint(ndpwr*oldph(k,ifit(me%np/2)))
        end do

    end if

    end subroutine report
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/encode
!
!  NAME
!    encode
!
!  DESCRIPTION
!    Encode phenotype parameters into integer genotype
!    ph(k) are x,y coordinates [ 0 < x,y < 1 ]
!
!  SOURCE

    subroutine encode(me,ph,gn)

    implicit none

    class(pikaia_class),intent(inout)         :: me
    real(wp),dimension(me%n),intent(in)       :: ph
    integer,dimension(me%n*me%nd),intent(out) :: gn

    integer  :: ip,i,j,ii
    real(wp) :: z

    z=10.0_wp**me%nd
    ii=0
    do i=1,me%n
        ip=int(ph(i)*z)
        do j=me%nd,1,-1
            gn(ii+j)=mod(ip,10)
            ip=ip/10
        end do
        ii=ii+me%nd
    end do

    end subroutine encode
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/decode
!
!  NAME
!    decode
!
!  DESCRIPTION
!    decode genotype into phenotype parameters
!    ph(k) are x,y coordinates [ 0 < x,y < 1 ]
!
!  SOURCE

    subroutine decode(me,gn,ph)

    implicit none

    class(pikaia_class),intent(inout)        :: me
    integer,dimension(me%n*me%nd),intent(in) :: gn
    real(wp),dimension(me%n),intent(out)     :: ph

    integer  :: ip,i,j,ii
    real(wp) :: z

    z=10.0_wp**(-me%nd)
    ii=0
    do i=1,me%n
        ip=0
        do j=1,me%nd
            ip=10*ip+gn(ii+j)
        end do
        ph(i)=ip*z
        ii=ii+me%nd
    end do

    end subroutine decode
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/cross
!
!  NAME
!    cross
!
!  DESCRIPTION
!    breeds two parent chromosomes into two offspring chromosomes
!    breeding occurs through crossover. If the crossover probability
!    test yields true (crossover taking place), either one-point or
!    two-point crossover is used, with equal probabilities.
!
!  NOTES
!    Compatibility with version 1.0: To enforce 100% use of one-point
!    crossover, un-comment appropriate line in source code below
!
!  SOURCE

    subroutine cross(me,gn1,gn2)

    implicit none

    class(pikaia_class),intent(inout)           :: me
    integer,dimension(me%n*me%nd),intent(inout) :: gn1
    integer,dimension(me%n*me%nd),intent(inout) :: gn2

    integer :: i, ispl, ispl2, itmp, t

    !Use crossover probability to decide whether a crossover occurs
    if (urand()<me%pcross) then

        !Compute first crossover point
        ispl=int(urand()*me%n*me%nd)+1

        !Now choose between one-point and two-point crossover
        if (urand()<0.5_wp) then
            ispl2=me%n*me%nd
        else
            ispl2=int(urand()*me%n*me%nd)+1
            !Un-comment following line to enforce one-point crossover
            !ispl2=me%n*me%nd
            if (ispl2<ispl) then
                itmp=ispl2
                ispl2=ispl
                ispl=itmp
            end if
        end if

        !Swap genes from ispl to ispl2
        do i=ispl,ispl2
            t=gn2(i)
            gn2(i)=gn1(i)
            gn1(i)=t
        end do

    end if

    end subroutine cross
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/mutate
!
!  NAME
!    mutate
!
!  DESCRIPTION
!    Introduces random mutation in a genotype.
!    Mutations occur at rate pmut at all gene loci.
!
!  INPUT
!    * imut=1    Uniform mutation, constant rate
!    * imut=2    Uniform mutation, variable rate based on fitness
!    * imut=3    Uniform mutation, variable rate based on distance
!    * imut=4    Uniform or creep mutation, constant rate
!    * imut=5    Uniform or creep mutation, variable rate based on fitness
!    * imut=6    Uniform or creep mutation, variable rate based on distance
!
!  SOURCE

    subroutine mutate(me,gn)

    implicit none

    class(pikaia_class),intent(inout)           :: me
    integer,dimension(me%n*me%nd),intent(inout) :: gn

    integer :: i,j,k,l,ist,inc,loc
    logical :: fix

    !Decide which type of mutation is to occur
    if (me%imut>=4 .and. urand()<=0.5_wp) then

        !CREEP MUTATION OPERATOR
        !Subject each locus to random +/- 1 increment at the rate pmut
        do i=1,me%n
            do j=1,me%nd

                if (urand()<me%pmut) then

                    !Construct integer
                    loc=(i-1)*me%nd+j
                    inc=nint ( urand() )*2-1
                    ist=(i-1)*me%nd+1
                    gn(loc)=gn(loc)+inc

                    !This is where we carry over the one (up to two digits)
                    !first take care of decrement below 0 case
                    if (inc<0 .and. gn(loc)<0) then
                        if (j==1) then
                            gn(loc)=0
                        else
                            fix = .true.
                            do k=loc,ist+1,-1
                                gn(k)=9
                                gn(k-1)=gn(k-1)-1
                                if ( gn(k-1)>=0 ) then
                                    fix = .false.
                                    exit
                                end if
                            end do
                            if (fix) then
                                !we popped under 0.00000 lower bound; fix it up
                                if ( gn(ist)<0.0_wp) then
                                    do l=ist,loc
                                        gn(l)=0
                                    end do
                                end if
                            end if
                        end if
                    end if

                    if (inc>0 .and. gn(loc)>9) then
                        if (j==1) then
                            gn(loc)=9
                        else
                            fix = .true.
                            do k=loc,ist+1,-1
                                gn(k)=0
                                gn(k-1)=gn(k-1)+1
                                if ( gn(k-1)<=9 ) then
                                    fix = .false.
                                    exit
                                end if
                            end do
                            if (fix) then
                                !we popped over 9.99999 upper bound; fix it up
                                if ( gn(ist)>9 ) then
                                    do l=ist,loc
                                        gn(l)=9
                                    end do
                                end if
                            end if
                        end if
                    end if

                end if

            end do
        end do

    else

        !UNIFORM MUTATION OPERATOR
        !Subject each locus to random mutation at the rate pmut
        do i=1,me%n*me%nd
            if (urand()<me%pmut) then
                gn(i)=int(urand()*10.0_wp)
            end if
        end do

    end if

    end subroutine mutate
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/adjmut
!
!  NAME
!    adjmut
!
!  DESCRIPTION
!    Dynamical adjustment of mutation rate:
!    * imut=2 or imut=5 : adjustment based on fitness differential
!      between best and median individuals
!    * imut=3 or imut=6 : adjustment based on metric distance
!      between best and median individuals
!
!  SOURCE

    subroutine adjmut(me,oldph,fitns,ifit)

    implicit none

    class(pikaia_class),intent(inout)         :: me
    integer,dimension(me%np),intent(in)       :: ifit
    real(wp),dimension(me%n,me%np),intent(in) :: oldph
    real(wp),dimension(me%np),intent(in)      :: fitns

    integer  :: i
    real(wp) :: rdif

    real(wp),parameter :: rdiflo = 0.05_wp
    real(wp),parameter :: rdifhi = 0.25_wp
    real(wp),parameter :: delta  = 1.5_wp

    if (me%imut==2 .or. me%imut==5) then

        !Adjustment based on fitness differential
        rdif = abs(fitns(ifit(me%np)) - &
               fitns(ifit(me%np/2)))/(fitns(ifit(me%np)) + &
               fitns(ifit(me%np/2)))

    else if (me%imut==3 .or. me%imut==6) then

        !Adjustment based on normalized metric distance
        rdif=0.0_wp
        do i=1,me%n
            rdif=rdif+( oldph(i,ifit(me%np))-oldph(i,ifit(me%np/2)) )**2
        end do
        rdif=sqrt( rdif ) / real(me%n,wp)

    end if

    if (rdif<=rdiflo) then
        me%pmut=min(me%pmutmx,me%pmut*delta)
    else if (rdif>=rdifhi) then
        me%pmut=max(me%pmutmn,me%pmut/delta)
    end if

    end subroutine adjmut
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/select_parent
!
!  NAME
!    select_parent
!
!  DESCRIPTION
!    Selects a parent from the population, using roulette wheel
!    algorithm with the relative fitnesses of the phenotypes as
!    the "hit" probabilities.
!
!  SEE ALSO
!    * Davis 1991, chap. 1.
!
!  SOURCE

    subroutine select_parent(me,jfit,idad)

    implicit none

    class(pikaia_class),intent(inout)   :: me
    integer,dimension(me%np),intent(in) :: jfit
    integer,intent(out)                 :: idad

    integer  :: np1,i
    real(wp) :: dice,rtfit

    np1 = me%np+1
    dice = urand()*me%np*np1
    rtfit = 0.0_wp
    do i=1,me%np
        rtfit = rtfit+np1+me%fdif*(np1-2*jfit(i))
        if (rtfit>=dice) then
            idad=i
            exit
        end if
    end do
    !Assert: loop will never exit by falling through

    end subroutine select_parent
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/rnkpop
!
!  NAME
!    rnkpop
!
!  DESCRIPTION
!    Ranks initial population.
!    Calls external sort routine to produce key index and rank order
!    of input array arrin (which is not altered).
!
!  SOURCE

    subroutine rnkpop(me,arrin,indx,rank)

    implicit none

    class(pikaia_class),intent(inout)     :: me
    real(wp),dimension(me%np),intent(in)  :: arrin
    integer,dimension(me%np),intent(out)  :: indx
    integer,dimension(me%np),intent(out)  :: rank

    integer :: i

    !Compute the key index
    call rqsort(me%np,arrin,indx)

    !and the rank order
    do i=1,me%np
        rank(indx(i)) = me%np-i+1
    end do

    end subroutine rnkpop
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/genrep
!
!  NAME
!    genrep
!
!  DESCRIPTION
!    Full generational replacement: accumulate offspring into new
!    population array
!
!  SOURCE

    subroutine genrep(me,ip,ph,newph)

    implicit none

    class(pikaia_class),intent(inout)          :: me
    integer,intent(in)                         :: ip
    real(wp),dimension(me%n,2),intent(in)      :: ph
    real(wp),dimension(me%n,me%np),intent(out) :: newph

    integer :: i1,i2,k

    !Insert one offspring pair into new population
    i1=2*ip-1
    i2=i1+1
    do k=1,me%n
        newph(k,i1)=ph(k,1)
        newph(k,i2)=ph(k,2)
    end do

    end subroutine genrep
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/stdrep
!
!  NAME
!    stdrep
!
!  DESCRIPTION
!     Steady-state reproduction: insert offspring pair into population
!     only if they are fit enough (replace-random if irep=2 or
!     replace-worst if irep=3).
!
!  SOURCE

    subroutine stdrep(me,ph,oldph,fitns,ifit,jfit,nnew)

    implicit none

    class(pikaia_class),intent(inout)             :: me
    real(wp),dimension(me%n,2),intent(in)         :: ph
    real(wp),dimension(me%n,me%np),intent(inout)  :: oldph
    real(wp),dimension(me%np),intent(inout)       :: fitns
    integer,dimension(me%np),intent(inout)        :: ifit
    integer,dimension(me%np),intent(inout)        :: jfit
    integer,intent(out)                           :: nnew

    integer  :: i,j,k,i1,if1
    real(wp) :: fit

    nnew = 0

    main_loop : do j=1,2

        !1. compute offspring fitness (with caller's fitness function)
        call me%ff(ph(:,j),fit)

        !2. if fit enough, insert in population
        do i=me%np,1,-1

            if (fit>fitns(ifit(i))) then

                !make sure the phenotype is not already in the population
                if (i<me%np) then
                    if (all(oldph(1:me%n,ifit(i+1))==ph(1:me%n,j))) exit main_loop
                end if

                !offspring is fit enough for insertion, and is unique

                !(i) insert phenotype at appropriate place in population
                if (me%irep==3) then
                    i1=1
                else if (me%ielite==0 .or. i==me%np) then
                    i1=int(urand()*me%np)+1
                else
                    i1=int(urand()*(me%np-1))+1
                end if
                if1 = ifit(i1)
                fitns(if1)=fit
                do k=1,me%n
                    oldph(k,if1)=ph(k,j)
                end do

                !(ii) shift and update ranking arrays
                if (i<i1) then

                    !shift up
                    jfit(if1)=me%np-i
                    do k=i1-1,i+1,-1
                        jfit(ifit(k))=jfit(ifit(k))-1
                        ifit(k+1)=ifit(k)
                    end do
                    ifit(i+1)=if1

                else

                    !shift down
                    jfit(if1)=me%np-i+1
                    do k=i1+1,i
                        jfit(ifit(k))=jfit(ifit(k))+1
                        ifit(k-1)=ifit(k)
                    end do
                    ifit(i)=if1

                end if

                nnew = nnew+1
                exit main_loop

            end if

        end do

    end do main_loop

    end subroutine stdrep
!*****************************************************************************************

!*****************************************************************************************
!****f* pikaia_module/newpop
!
!  NAME
!    newpop
!
!  DESCRIPTION
!    Replaces old population by new; recomputes fitnesses & ranks
!
!  HISTORY
!    Jacob Williams : 3/9/2015 : avoid unnecessary function evaluation if ielite/=1.
!
!  SOURCE

    subroutine newpop(me,oldph,newph,ifit,jfit,fitns,nnew)

    implicit none

    class(pikaia_class),intent(inout)            :: me
    real(wp),dimension(me%n,me%np),intent(inout) :: oldph
    real(wp),dimension(me%n,me%np),intent(inout) :: newph
    integer,dimension(me%np),intent(out)         :: ifit
    integer,dimension(me%np),intent(out)         :: jfit
    real(wp),dimension(me%np),intent(out)        :: fitns
    integer,intent(out)                          :: nnew

    integer  :: i
    real(wp) :: f

    nnew = me%np

    if (me%ielite==1) then

        !if using elitism, introduce in new population fittest of old
        !population (if greater than fitness of the individual it is
        !to replace)
        call me%ff(newph(:,1),f)

        if (f<fitns(ifit(me%np))) then
            newph(:,1)=oldph(:,ifit(me%np))
            nnew = nnew-1
        end if

    end if

    !replace population
    do i=1,me%np

        oldph(:,i)=newph(:,i)

        !get fitness using caller's fitness function
        call me%ff(oldph(:,i),fitns(i))

    end do

    !compute new population fitness rank order
    call me%rnkpop(fitns,ifit,jfit)

    end subroutine newpop
!*****************************************************************************************

!*****************************************************************************************
    end module pikaia_module
!*****************************************************************************************