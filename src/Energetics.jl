"""
	V = lennard_jones_potential_energy(r::Float64, σ::Float64, ϵ::Float64) # units: Kelvin

Calculate the lennard jones potential energy given a radius r between two molecules.
σ and ϵ are specific to interaction between two elements.
returns potential energy in units Kelvin.
# Arguments
- `r::Float64`: distance between two (pseudo)atoms in question (Angstrom)
- `σ::Float64`: sigma parameter in Lennard Jones potential (units: Angstrom)
- `ϵ::Float64`: epsilon parameter in Lennard Jones potential (units: Kelvin)
"""
function lennard_jones(r::Float64, σ::Float64, ϵ::Float64)
	ratio = (σ / r) ^ 6
	return 4 * ϵ * (ratio ^ 2 - ratio)
end

"""
    V = vdw_energy(framework::Framework, molecule::Molecule, ljforcefield::LennardJonesForceField, repfactors::Array{Int64})

Calculates the van der Waals energy for a molecule locates at a specific position in a MOF 
supercell. Uses the nearest image convention to find the closest replicate of a specific atom
# Arguments
- `framework::Framework`: Crystal structure
- `molecule::Molecule`: adsorbate (includes position/orientation)
- `ljforcefield::LennardJonesForceField`: Lennard Jones force field
- `repfactors::Tuple{Int, Int, Int}`: replication factors of the home unit cell to build 
the supercell, which is the simulation box, such that the nearest image convention can be 
applied in this function.
"""
function vdw_energy(framework::Framework, molecule::Molecule, 
                    ljforcefield::LennardJonesForceField, repfactors::Tuple{Int, Int, Int})
	energy = 0.0
    # loop over replications of the home unit cell to build the supercell (simulation box)
	for nA = 0:repfactors[1]-1, nB = 0:repfactors[2]-1, nC = 0:repfactors[3]-1
        # loop over atoms of the molecule/adsorbate
        # TODO: think about whether i or k loop should go first for speed. might not matter.
		for i = 1:molecule.n_atoms 
            # loop over framework atoms in the home unit cell
			for k = 1:framework.n_atoms
				# Nearest image convention. 
                #  If the interaction between the probe molecule and atom k is being looked 
                #  at, we'll only look at the interaction between the probe molecule and 
                #  the closest replication of atom k. This is done with fractional 
                #  coordinates for simplication and transformation to cartesian is done 
                #  later.
				repvec = [nA, nB, nC]

				dx = abs((framework.C_to_f*molecule.pos)[1]-(framework.f_coords[1,k]+nA))
				if dx > repfactors[1] / 2
					repvec += sign(dx) * [repfactors[1], 0, 0]
				end

				dy = abs((framework.C_to_f*molecule.pos)[2]-(framework.f_coords[2,k]+nB))
				if dy > repfactors[2] / 2
					repvec += sign(dy) * [0, repfactors[2], 0]
				end

				dz = abs((framework.C_to_f*molecule.pos)[3]-(framework.f_coords[3,k]+nC))
				if dz > repfactors[3] / 2
					repvec += sign(dz) * [0, 0, repfactors[3]]
				end
#				println(repvec)
#				println("==========================\n")
                
                # Cartesian coordinates of nearest image framework atom.
				x_k = framework.f_to_C * (framework.f_coords[:, k] + repvec)
                
                # TODO for speedup, wouldn't r2 be faster? then work with r2.
				r = vecnorm(molecule.pos[:, i] - x_k)

				σ = ljforcefield.sigmas[framework.atoms[k], molecule.atoms[i]]
                # TODO note that r^2 is faster; maybe store sigma2
				ϵ = ljforcefield.epsilons[framework.atoms[k], molecule.atoms[i]]
                
                # TODO if changing to r2, easier to story cutoffradis_squared and compare to
                # TODO  r^2 instead.
				if r < ljforcefield.cutoffradius
#					@printf("Calling lennard_jones(%f,%f,%f)\n",r,σ,ϵ)
 # 					if lennard_jones(r,σ,ϵ) > 0
#						@printf("%s-%d (nA = %d, nB = %d, nC = %d) and %s-%d -> r = %f | pos = [%f,%f,%f]\n",framework.atoms[k],k,nA,nB,nC,molecule.atoms[i],i,r,pos[1],pos[2],pos[3])
#					@printf("pos = [%f,%f,%f], framework.f_to_C*(framework.f_coords[k,:]+repvec) = [%f,%f,%f]\n",molecule.x[1],molecule.x[2],molecule.x[3],temp[1],temp[2],temp[3])
 # 					end
                    # add pairwise contribution to potential energy
				    energy += lennard_jones(r, σ, ϵ)
				end
			end
		end
	end
	return energy
end # vdw_energy end
