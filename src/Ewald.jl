# Vacuum permittivity eps0 = 8.854187817e-12 # C^2/(J-m)
# 1 m = 1e10 A, 1 e = 1.602176e-19 C, kb = 1.3806488e-23 J/K
# 8.854187817e-12 C^2/(J-m) [1 m / 1e10 A] [1 e / 1.602176e-19 C]^2 [kb = 1.3806488e-23 J/K]
const ϵ₀ = 4.7622424954949676e-7  # \epsilon_0 vacuum permittivity units: electron charge^2 /(A - K)

# TODO use NIST test data https://www.nist.gov/mml/csd/chemical-informatics-research-group/spce-water-reference-calculations-10%C3%A5-cutoff
#   to untar: tar zxvf spce_sample_configurations-tar.gz

struct Kvector
    "The reciprocal vector k"
    k::Array{Float64, 1}
    "The corresponding weight on the contribution of this k-vector to the long-range EWald sum"
    weight::Float64
end

"""
    kvectors = compute_kvectors(sim_box, k_rep_factors, α)

For speed, pre-compute k-vectors.
"""
function compute_kvectors(sim_box::Box, k_rep_factors::Tuple{Int, Int, Int}, α::Float64)
    kvectors = Kvector[]
    for ka = -k_rep_factors[1]:1.0:k_rep_factors[1], kb = -k_rep_factors[2]:1.0:k_rep_factors[2], kc=-k_rep_factors[3]:1.0:k_rep_factors[3]
        if (ka == 0) && (kb == 0) && (kc == 0)
            continue
        end

        # reciprocal vector, k
        k = sim_box.reciprocal_lattice * [ka, kb, kc]
        # |k|²
        norm_squared = dot(k, k)
        weight = exp(- norm_squared / (4.0 * α ^ 2)) / norm_squared / ϵ₀

        push!(kvectors, Kvector(k, weight))
    end
    return kvectors
end

"""
# Arguments
- `framework::Framework`: Crystal structure (includes charge)
- `repfactors::Tuple{Int64, Int64, Int64}`: The replication factors used to form the supercell
- `α::Float64`: Ewald sum convergence parameter
"""
function electrostatic_potential(framework::Framework, x::Array{Float64, 1}, 
                                 sim_box::Box, rep_factors::Tuple{Int, Int, Int}, sr_cutoff_radius::Float64,
                                 kvectors::Array{Kvector, 1}, α::Float64)
    # fractional coordinate of point at which we're computing the electrostatic potential (wrap to [0, 1.0])
    xf = mod.(framework.box.c_to_f * x, 1.0)

	sr_potential = 0.0 # short-range contribution
	lr_potential = 0.0 # long-range contribution
    # build the super cell with loop over (ra, rb, rc) and atoms in the primitive unit cell
    for ra = 0:(rep_factors[1] - 1), rb = 0:(rep_factors[2] - 1), rc = 0:(rep_factors[3] - 1)
        # x - x_i vector in fractional coords; i corresponds to atom of framework.
        #  same as: dxf = xf - (framework.xf[:, i] + [ra, rb, rc]) = (xf - [ra, rb, rc]) - framework.xf[:, i]
        dxf = broadcast(-, xf - [ra, rb, rc], framework.xf)
        # convert distance vector to Cartesian coordinates
        dx = framework.box.f_to_c * dxf
        
        ###
        #  Long-range contribution
        ###
        for i = 1:framework.n_atoms
            for kvector in kvectors
                # k ⋅ (x - x_a)
                k_dot_dx = kvector.k[1] * dx[1, i] + kvector.k[2] * dx[2, i] + kvector.k[3] * dx[3, i]
                lr_potential += framework.charges[i] * cos(k_dot_dx) * kvector.weight
            end
        end

        ###
        #  Short range contribution
        ###
        # apply nearest image convention for periodic BCs
        nearest_image!(dxf, rep_factors)

        # convert distance vector to Cartesian coordinates
        dx = framework.box.f_to_c * dxf

        r = mapslices(norm, dx, 1)
        
        for i = 1:framework.n_atoms
            if r[i] < sr_cutoff_radius
                sr_potential += framework.charges[i] / r[i] * erfc(r[i] * α)
            end
        end
    end
    sr_potential /= 4.0 * π * ϵ₀
    lr_potential /= sim_box.Ω

    return lr_potential + sr_potential
end		

function ϕ_sr(framework::Framework, x::Array{Float64, 1}, rep_factors::Tuple{Int, Int, Int}, sr_cutoff_radius::Float64, α::Float64)
    # fractional coordinate of point at which we're computing the electrostatic potential (wrap to [0, 1.0])
    xf = mod.(framework.box.c_to_f * x, 1.0)

	sr_potential = 0.0 # short-range contribution
    # build the super cell with loop over (ra, rb, rc) and atoms in the primitive unit cell
    for ra = 0:1.0:(rep_factors[1] - 1), rb = 0:1.0:(rep_factors[2] - 1), rc = 0:1.0:(rep_factors[3] - 1)
        # x - x_i vector in fractional coords; i corresponds to atom of framework.
        #  same as: dxf = xf - (framework.xf[:, i] + [ra, rb, rc]) = (xf - [ra, rb, rc]) - framework.xf[:, i]
        dx = broadcast(-, xf - [ra, rb, rc], framework.xf)
        nearest_image!(dx, rep_factors)
        # convert distance vector to Cartesian coordinates
        dx = framework.box.f_to_c * dx
        
        r = mapslices(norm, dx, 1)
        sr_potential += sum(framework.charges ./ r .* erfc.(r * α))
    end
    sr_potential /= 4.0 * π * ϵ₀

    return sr_potential
end

function ϕ_lr(framework::Framework, x::Array{Float64, 1}, sim_box::Box, rep_factors::Tuple{Int, Int, Int}, kvectors::Array{Kvector, 1}, α::Float64)
    # fractional coordinate of point at which we're computing the electrostatic potential (wrap to [0, 1.0])
    xf = mod.(framework.box.c_to_f * x, 1.0)

	lr_potential = 0.0 # long-range contribution
    # build the super cell with loop over (ra, rb, rc) and atoms in the primitive unit cell
    for ra = 0:1.0:(rep_factors[1] - 1), rb = 0:1.0:(rep_factors[2] - 1), rc = 0:1.0:(rep_factors[3] - 1)
        # x - x_i vector in fractional coords; i corresponds to atom of framework.
        #  same as: dxf = xf - (framework.xf[:, i] + [ra, rb, rc]) = (xf - [ra, rb, rc]) - framework.xf[:, i]
        dxf = broadcast(-, xf - [ra, rb, rc], framework.xf)
        # convert distance vector to Cartesian coordinates
        dx = framework.box.f_to_c * dxf
        
        ###
        #  Long-range contribution
        ###
        lr_potential = 0.0
        for i = 1:framework.n_atoms
            for kvector in kvectors
                # k ⋅ (x - x_a)
                k_dot_dx = kvector.k[1] * dx[1, i] + kvector.k[2] * dx[2, i] + kvector.k[3] * dx[3, i]
                @fastmath lr_potential += framework.charges[i] * cos(k_dot_dx) * kvector.weight
            end
        end
    end
    lr_potential /= sim_box.Ω

    return lr_potential
end		
