# This function is very important for the computation of Floquet multipliers and checks that the eigensolvers compute the eigenvalues with largest modulus instead of their default behaviour which is with largest real part. If this option is not properly set, bifurcations of periodic orbits will be missed.
function checkFloquetOptions(eigls::AbstractEigenSolver)
	if eigls isa DefaultEig
		return @set eigls.which = abs
	elseif eigls isa EigArpack
		return setproperties(eigls; which = :LM, by = abs)
	elseif eigls isa EigArnoldiMethod
		return setproperties(eigls; which = ArnoldiMethod.LM(), by = abs)
	end
	if eigls isa EigKrylovKit
		return @set eigls.which = :LM
	end
end

####################################################################################################
# Computation of Floquet Coefficients for periodic orbits problems based on Finite Differences
"""
bla
"""
struct FloquetTrap <: AbstractFloquetSolver; end

function (fl::FloquetTrap)(J::AbstractMatrix, nev; kwargs...)
	# we build the monodromy matrix and compute the spectrum
	Aγ = J[1:end-1,1:end-1]

	# we extract the eigenvalues
	vals, vecs, cv, info = fl.eigsolver(monodromy, nev)
	# the `vals` should be sorted by largest modulus, but we need the log of them sorted this way
	logvals = log.(complex.(vals))
	I = sortperm(logvals, by = x-> real(x), rev = true)
	# Base.display(logvals)
	return logvals[I], geteigenvector(fl.eigsolver, vecs, I), cv, info
end
####################################################################################################
# Computation of Floquet Coefficients for periodic orbit problems

"""
	floquet = FloquetQaD(eigsolver::AbstractEigenSolver)

This composite type implements the computation of the eigenvalues of the monodromy matrix in the case of periodic orbits problems (based on the Shooting method or Finite Differences (Trapeze method)), also called the Floquet multipliers. The method, dubbed Quick and Dirty (QaD), is not numerically very precise for large / small Floquet exponents. It allows, nevertheless, to detect bifurcations. The arguments are as follows:
- `eigsolver::AbstractEigenSolver` solver used to compute the eigenvalues.

If `eigsolver == DefaultEig()`, then the monodromy matrix is formed and its eigenvalues are computed. Otherwise, a Matrix-Free version of the monodromy is used.

!!! danger "Floquet multipliers computation"
    The computation of Floquet multipliers is necessary for the detection of bifurcations of periodic orbits (which is done by analyzing the Floquet exponents obtained from the Floquet multipliers). Hence, the eigensolver `eigsolver` needs to compute the eigenvalues with largest modulus (and not with largest real part which is their default behavior). This can be done by changing the option `which = :LM` of `eigsolver`. Nevertheless, note that for most implemented eigensolvers in the current Package, the proper option is set.
"""
struct FloquetQaD{E <: AbstractEigenSolver } <: AbstractFloquetSolver
	eigsolver::E
	function FloquetQaD(eigls::AbstractEigenSolver)
		eigls2 = checkFloquetOptions(eigls)
		return new{typeof(eigls2)}(eigls2)
	end
end

function (fl::FloquetQaD)(J, nev; kwargs...)
	if fl.eigsolver isa DefaultEig
		@warn "Not implemented yet in a fast way! Need to form the full monodromy matrix, not practical for large scale problems"
		# we build the monodromy matrix and compute the spectrum
		monodromy = MonodromyQaD(J)
	else
		# we use a Matrix Free version
		monodromy = dx -> MonodromyQaD(J, dx)
	end
	vals, vecs, cv, info = fl.eigsolver(monodromy, nev)
	Inf in vals && @warn "Detecting infinite eigenvalue during the computation of Floquet coefficients"

	# the `vals` should be sorted by largest modulus, but we need the log of them sorted this way
	logvals = log.(complex.(vals))
	# Base.display(logvals)
	I = sortperm(logvals, by = real, rev = true)
	return logvals[I], geteigenvector(fl.eigsolver, vecs, I), cv, info
end

##############################################
# ShootingProblem
function MonodromyQaD(JacSH::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}, du::AbstractVector) where {Tpb <: ShootingProblem, Tjacpb, Torbitguess, Tp}
	sh = JacSH.pb
	x = JacSH.x
	p = JacSH.par

	# period of the cycle
	T = extractPeriodShooting(x)

	# extract parameters
	M = getM(sh)
	N = div(length(x) - 1, M)

	# extract the time slices
	xv = @view x[1:end-1]
	xc = reshape(xv, N, M)

	out = copy(du)

	for ii in 1:M
		# call the jacobian of the flow
		@views out .= sh.flow(Val(:SerialdFlow), xc[:, ii], p, out, sh.ds[ii] * T).du
	end
	return out
end

# Compute the monodromy matrix at `x` explicitely, not suitable for large systems
function MonodromyQaD(JacSH::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}) where {Tpb <: ShootingProblem, Tjacpb, Torbitguess, Tp}
	sh = JacSH.pb
	x = JacSH.x
	p = JacSH.par

	# period of the cycle
	T = extractPeriodShooting(x)

	# extract parameters
	M = getM(sh)

	N = div(length(x) - 1, M)

	Mono = zeros(N, N)

	# extract the time slices
	xv = @view x[1:end-1]
	xc = reshape(xv, N, M)
	du = zeros(N)

	for ii in 1:N
		du[ii] = 1
		# call jacobian of the flow
		@views Mono[:, ii] .= sh.flow(Val(:SerialdFlow), xc[:, 1], p, du, T).du
		du[ii] = 0
	end

	return Mono
end

function MonodromyQaD(JacSH::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}) where {Tpb <: ShootingProblem, Tjacpb <: AbstractMatrix, Torbitguess, Tp}
	J = JacSH.jacpb
	sh = JacSH.pb
	M = getM(sh)
	N = div(length(JacSH.x) - 1, M)

	mono = J[1:N, 1:N]
	tmp = similar(mono)
	r = N
	for ii = 1:M-1
		# mono .= J[r+1:r+N, r+1:r+N] * mono
		@views mul!(tmp, J[r+1:r+N, r+1:r+N], mono)
		mono .= tmp
		r += N
	end
	return mono
end

##############################################
# PoincareShooting
function MonodromyQaD(JacSH::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}, dx_bar::AbstractVector) where {Tpb <: PoincareShootingProblem, Tjacpb, Torbitguess, Tp}
	psh = JacSH.pb
	x_bar = JacSH.x
	p = JacSH.par

	M = getM(psh)
	Nm1 = div(length(x_bar), M)

	# reshape the period orbit guess into a Matrix
	x_barc = reshape(x_bar, Nm1, M)
	@assert length(dx_bar) == Nm1 "Please provide the right dimension to your matrix-free eigensolver, it must be $Nm1."

	xc = similar(x_bar, Nm1 + 1)
	outbar = copy(dx_bar)
	outc = similar(dx_bar, Nm1 + 1)

	for ii in 1:M
		E!(psh.section,  xc,  view(x_barc, :, ii), ii)
		dE!(psh.section, outc, outbar, ii)
		outc .= diffPoincareMap(psh, xc, p, outc, ii)
		# check to <outc, normals[ii]> = 0
		# println("--> ii=$ii, <out, normali> = ", dot(outc, sh.section.normals[ii]))
		dR!(psh.section, outbar, outc, ii)
	end
	return outbar

end

function MonodromyQaD(JacSH::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}) where {Tpb <: PoincareShootingProblem, Tjacpb, Torbitguess, Tp}
	@assert 1==0 "WIP, no done yet! Please use an iterative eigensolver for the computation of Floquet coefficients using Poincaré shooting."
end

##############################################
# PeriodicOrbitTrapProblem
function MonodromyQaD(JacFW::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}, du::AbstractVector) where {Tpb <: PeriodicOrbitTrapProblem, Tjacpb, Torbitguess, Tp}
	poPb = JacFW.pb
	u0 = JacFW.x
	par = JacFW.par

	# extraction of various constants
	M, N = size(poPb)

	# period of the cycle
	T = extractPeriodFDTrap(u0)

	# time step
	h =  T * getTimeStep(poPb, 1)
	Typeh = typeof(h)

	out = copy(du)

	u0c = extractTimeSlices(u0, N, M)

	@views out .= out .+ h/2 .* apply(poPb.J(u0c[:, M-1], par), out)
	# res = (I - h/2 * poPb.J(u0c[:, 1])) \ out
	@views res, _ = poPb.linsolver(poPb.J(u0c[:, 1], par), out; a₀ = convert(Typeh, 1), a₁ = -h/2)
	out .= res

	for ii in 2:M-1
		h =  T * getTimeStep(poPb, ii)
		@views out .= out .+ h/2 .* apply(poPb.J(u0c[:, ii-1], par), out)
		# res = (I - h/2 * poPb.J(u0c[:, ii])) \ out
		@views res, _ = poPb.linsolver(poPb.J(u0c[:, ii], par), out; a₀ = convert(Typeh, 1), a₁ = -h/2)
		out .= res
	end

	return out
end

function MonodromyQaD(::Val{:ExtractEigenVector}, poPb::PeriodicOrbitTrapProblem, u0::AbstractVector, par, du::AbstractVector)
	# extraction of various constants
	M = poPb.M
	N = poPb.N

	# period of the cycle
	T = extractPeriodFDTrap(u0)

	# time step
	h =  T * getTimeStep(poPb, 1)
	Typeh = typeof(h)

	out = copy(du)

	u0c = extractTimeSlices(u0, N, M)

	@views out .= out .+ h/2 .* apply(poPb.J(u0c[:, M-1], par), out)
	# res = (I - h/2 * poPb.J(u0c[:, 1])) \ out
	@views res, _ = poPb.linsolver(poPb.J(u0c[:, 1], par), out; a₀ = convert(Typeh, 1), a₁ = -h/2)
	out .= res
	out_a = [copy(out)]
	# push!(out_a, copy(out))

	for ii in 2:M-1
		h =  T * getTimeStep(poPb, ii)
		@views out .= out .+ h/2 .* apply(poPb.J(u0c[:, ii-1], par), out)
		# res = (I - h/2 * poPb.J(u0c[:, ii])) \ out
		@views res, _ = poPb.linsolver(poPb.J(u0c[:, ii], par), out; a₀ = convert(Typeh, 1), a₁ = -h/2)
		out .= res
		push!(out_a, copy(out))
	end
	push!(out_a, copy(du))

	return out_a
end

# Compute the monodromy matrix at `u0` explicitely, not suitable for large systems
function MonodromyQaD(JacFW::FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp})  where {Tpb <: PeriodicOrbitTrapProblem, Tjacpb, Torbitguess, Tp}

	poPb = JacFW.pb
	u0 = JacFW.x
	par = JacFW.par

	# extraction of various constants
	M, N = size(poPb)

	# period of the cycle
	T = extractPeriodFDTrap(u0)

	# time step
	h =  T * getTimeStep(poPb, 1)

	u0c = extractTimeSlices(u0, N, M)

	@views mono = Array(I - h/2 * (poPb.J(u0c[:, 1], par))) \ Array(I + h/2 * poPb.J(u0c[:, M-1], par))
	temp = similar(mono)

	for ii in 2:M-1
		# for some reason, the next line is faster than doing (I - h/2 * (poPb.J(u0c[:, ii]))) \ ...
		# also I - h/2 .* J seems to hurt (a little) the performances
		h =  T * getTimeStep(poPb, ii)
		@views temp = Array(I - h/2 * (poPb.J(u0c[:, ii], par))) \ Array(I + h/2 * poPb.J(u0c[:, ii-1], par))
		mono .= temp * mono
	end
	return mono
end
