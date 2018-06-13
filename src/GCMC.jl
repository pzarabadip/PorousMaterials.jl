import Base: +
using StatsBase

const KB = 1.38064852e7 # Boltmann constant (Pa-m3/K --> Pa-A3/K)

# define Markov chain proposals here.
const PROPOSAL_ENCODINGS = Dict(1 => "insertion", 2 => "deletion", 3 => "translation", 4 => "reinsertion")
const N_PROPOSAL_TYPES = length(keys(PROPOSAL_ENCODINGS))
const INSERTION   = Dict([v => k for (k, v) in PROPOSAL_ENCODINGS])["insertion"]
const DELETION    = Dict([v => k for (k, v) in PROPOSAL_ENCODINGS])["deletion"]
const TRANSLATION = Dict([v => k for (k, v) in PROPOSAL_ENCODINGS])["translation"]
const REINSERTION = Dict([v => k for (k, v) in PROPOSAL_ENCODINGS])["reinsertion"]
# define probabilty of proposing each type of MC move here. from StatsBase.jl
const PROBABILITIES_OF_MC_PROPOSALS = ProbabilityWeights([0.35, 0.35, 0.2, 0.1])
@assert(PROBABILITIES_OF_MC_PROPOSALS[INSERTION] ≈ PROBABILITIES_OF_MC_PROPOSALS[DELETION], "insertion/deletion probabilities must be equal")
@assert(length(PROBABILITIES_OF_MC_PROPOSALS) == N_PROPOSAL_TYPES, "probability of each MC proposal not specified")
@assert(sum(PROBABILITIES_OF_MC_PROPOSALS) ≈ 1.0, "sum of probabilities of MC moves should be 1.0")

# break collection of statistics into blocks to gauge convergence
const N_BLOCKS = 5

"""
Data structure to keep track of statistics collected during a grand-canonical Monte Carlo
simulation.

* `n` is the number of molecules in the simulation box.
* `V` is the potential energy.
* `g` refers to guest (the adsorbate molecule).
* `h` refers to host (the crystalline framework).
"""
type GCMCstats
    n_samples::Int

    n::Int
    n²::Int

    U::PotentialEnergy
    U²::PotentialEnergy

    Un::Float64 # ⟨U n⟩
end

# constructor
GCMCstats() = GCMCstats(0, 0, 0, PotentialEnergy(0.0, 0.0, 0.0, 0.0), PotentialEnergy(0.0, 0.0, 0.0, 0.0), 0.0)

# adding two stats.
+(s1::GCMCstats, s2::GCMCstats) = GCMCstats(s1.n_samples + s2.n_samples,
                                            s1.n + s2.n,
                                            s1.n² + s2.n²,
                                            s1.U + s2.U,
                                            s1.U² + s2.U²,
                                            s1.Un + s2.Un)

function Base.print(gcmc_stats::GCMCstats)
    println("\t# samples: ", gcmc_stats.n_samples)
    println("\t⟨N⟩ (molecules) = ", gcmc_stats.n / gcmc_stats.n_samples)

    println("\t⟨U_gg, vdw⟩ (K) = ",     gcmc_stats.U.vdw_gg     / gcmc_stats.n_samples)
    println("\t⟨U_gg, electro⟩ (K) = ", gcmc_stats.U.electro_gg / gcmc_stats.n_samples)
    println("\t⟨U_gh, vdw⟩ (K) = ",     gcmc_stats.U.vdw_gh     / gcmc_stats.n_samples)
    println("\t⟨U_gh, electro⟩ (K) = ", gcmc_stats.U.electro_gh / gcmc_stats.n_samples)

    println("\t⟨U⟩ (K) = ", sum(gcmc_stats.U) / gcmc_stats.n_samples)
end

"""
Keep track of Markov chain transitions (proposals and acceptances) during a grand-canonical
Monte Carlo simulation. Entry `i` of these arrays corresponds to PROPOSAL_ENCODINGS[i].
"""
type MarkovCounts
    n_proposed::Array{Int, 1}
    n_accepted::Array{Int, 1}
end

# TODO move this to MC helpers? but not sure if it will inline. so wait after test with @time
@inline function potential_energy(molecule_id::Int,
                                  molecules::Array{Molecule, 1},
                                  framework::Framework,
                                  ljforcefield::LennardJonesForceField,
                                  simulation_box::Box,
                                  repfactors::Tuple{Int, Int, Int},
                                  eparams::EwaldParams,
                                  kvectors::Array{Kvector, 1},
                                  eikar::OffsetArray{Complex{Float64}},
                                  eikbr::OffsetArray{Complex{Float64}},
                                  eikcr::OffsetArray{Complex{Float64}},
                                  charged_molecules::Bool,
                                  charged_framework::Bool)
    energy = PotentialEnergy(0.0, 0.0, 0.0, 0.0)
    energy.vdw_gg = vdw_energy(molecule_id, molecules, ljforcefield, simulation_box)
    energy.vdw_gh = vdw_energy(framework, molecules[molecule_id], ljforcefield, repfactors)
    if charged_molecules
        energy.electro_gg = electrostatic_potential_energy(molecules, molecule_id, eparams, kvectors, eikar, eikbr, eikcr)
        if charged_framework
            energy.electro_gh = electrostatic_potential_energy(framework, molecules[molecule_id], repfactors, eparams, kvectors, eikar, eikbr, eikcr)
        end
    end
    return energy
end

"""
    results = adsorption_isotherm(framework, temperature, fugacities, molecule,
                                  ljforcefield; n_sample_cycles=100000,
                                  n_burn_cycles=10000, sample_frequency=10,
                                  verbose=false, molecules=Molecule[],
                                  ewald_precision=1e-6)

Run a set of grand-canonical (μVT) Monte Carlo simulations in series. Arguments are the
same as [`gcmc_simulation`](@ref), as this is the function run behind the scenes. An
exception is that we pass an array of fugacities. The adsorption isotherm is computed step-
wise, where the ending configuration from the previous simulation (array of molecules) is
passed into the next simulation as a starting point. The ordering of `fugacities` is
honored. By giving each simulation a good starting point, (if the next fugacity does not
differ significantly from the previous fugacity), we can reduce the number of burn cycles
required to reach equilibrium in the Monte Carlo simulation. Also see
[`adsorption_isotherm`](@ref) which runs the μVT simulation at each fugacity in parallel.
"""
function stepwise_adsorption_isotherm(framework::Framework, temperature::Float64,
                                      fugacities::Array{Float64, 1}, molecule::Molecule,
                                      ljforcefield::LennardJonesForceField;
                                      n_burn_cycles::Int=10000, n_sample_cycles::Int=100000,
                                      sample_frequency::Int=10, verbose::Bool=false,
                                      ewald_precision::Float64=1e-6)
    results = Dict{String, Any}[] # push results to this array
    molecules = Molecule[] # initiate with empty framework
    for fugacity in fugacities
        result, molecules = gcmc_simulation(framework, temperature, fugacity, molecule,
                                            ljforcefield, n_burn_cycles=n_burn_cycles,
                                            n_sample_cycles=n_sample_cycles,
                                            sample_frequency=sample_frequency,
                                            verbose=verbose, molecules=molecules,
                                            ewald_precision=ewald_precision)
        push!(results, result)
    end

    return results
end

"""
    results = adsorption_isotherm(framework, temperature, fugacities, molecule,
                                  ljforcefield; n_sample_cycles=100000,
                                  n_burn_cycles=10000, sample_frequency=25,
                                  verbose=false, molecules=Molecule[],
                                  ewald_precision=1e-6)

Run a set of grand-canonical (μVT) Monte Carlo simulations in parallel. Arguments are the
same as [`gcmc_simulation`](@ref), as this is the function run in parallel behind the scenes.
The only exception is that we pass an array of fugacities. To give Julia access to multiple
cores, run your script as `julia -p 4 mysim.jl` to allocate e.g. four cores. See
[Parallel Computing](https://docs.julialang.org/en/stable/manual/parallel-computing/#Parallel-Computing-1).
"""
function adsorption_isotherm(framework::Framework, temperature::Float64,
                             fugacities::Array{Float64, 1}, molecule::Molecule,
                             ljforcefield::LennardJonesForceField;
                             n_burn_cycles::Int=10000, n_sample_cycles::Int=100000,
                             sample_frequency::Int=25, verbose::Bool=false,
                             ewald_precision::Float64=1e-6)
    # make a function of fugacity only to facilitate uses of `pmap`
    run_fugacity(fugacity::Float64) = gcmc_simulation(framework, temperature, fugacity,
                                                      molecule, ljforcefield,
                                                      n_burn_cycles=n_burn_cycles,
                                                      n_sample_cycles=n_sample_cycles,
                                                      sample_frequency=sample_frequency,
                                                      verbose=verbose,
                                                      ewald_precision=ewald_precision)[1] # only return results

    # for load balancing, larger pressures with longer computation time goes first
    ids = sortperm(fugacities, rev=true)

    # run gcmc simulations in parallel using Julia's pmap parallel computing function
    results = pmap(run_fugacity, fugacities[ids])

    # return results in same order as original fugacity even though we permuted them for
    #  better load balancing.
    return results[[find(x -> x==i, ids)[1] for i = 1:length(ids)]]
end


"""
    results, molecules = gcmc_simulation(framework, temperature, fugacity, molecule,
                                         ljforcefield; n_sample_cycles=100000,
                                         n_burn_cycles=10000, sample_frequency=25,
                                         verbose=false, molecules=Molecule[])

Runs a grand-canonical (μVT) Monte Carlo simulation of the adsorption of a molecule in a
framework at a particular temperature and fugacity (= pressure for an ideal gas) using a
Lennard Jones force field.

A cycle is defined as max(20, number of adsorbates currently in the system) Markov chain
proposals. Current Markov chain moves implemented are particle insertion/deletion and
translation.

# Arguments
- `framework::Framework`: the porous crystal in which we seek to simulate adsorption
- `temperature::Float64`: temperature of bulk gas phase in equilibrium with adsorbed phase
    in the porous material. units: Kelvin (K)
- `fugacity::Float64`: fugacity of bulk gas phase in equilibrium with adsorbed phase in the
    porous material. Equal to pressure for an ideal gas. units: Pascal (Pa)
- `molecule::Molecule`: a template of the adsorbate molecule of which we seek to simulate
    the adsorption
- `ljforcefield::LennardJonesForceField`: the molecular model used to describe the
    energetics of the adsorbate-adsorbate and adsorbate-host van der Waals interactions.
- `n_burn_cycles::Int`: number of cycles to allow the system to reach equilibrium before
    sampling.
- `n_sample_cycles::Int`: number of cycles used for sampling
- `sample_frequency::Int`: during the sampling cycles, sample e.g. the number of adsorbed
    gas molecules every this number of Markov proposals.
- `verbose::Bool`: whether or not to print off information during the simulation.
- `molecules::Array{Molecule, 1}`: a starting configuration of molecules in the framework
"""
function gcmc_simulation(framework::Framework, temperature::Float64, fugacity::Float64,
                         molecule::Molecule, ljforcefield::LennardJonesForceField;
                         n_burn_cycles::Int=10000, n_sample_cycles::Int=100000,
                         sample_frequency::Int=25, verbose::Bool=false,
                         molecules::Array{Molecule, 1}=Molecule[],
                         ewald_precision::Float64=1e-6)
    tic()
    if verbose
        pretty_print(molecule.species, framework.name, temperature, fugacity)
    end

    # replication factors for applying nearest image convention for short-range
    #   interactions
    const repfactors = replication_factors(framework.box, ljforcefield)
    # the simulation box = replicated primitive framework box
    const simulation_box = replicate_box(framework.box, repfactors)
    # TODO: assert center of mass is origin and make rotate! take optional argument to assume com is at origin?
    const molecule_template = deepcopy(molecule)
    if ! (total_charge(molecule_template) ≈ 0.0)
        error("Molecule in GCMC simulation must be charge neutral.\n")
    end

    if ! (check_forcefield_coverage(framework, ljforcefield) & check_forcefield_coverage(molecule, ljforcefield))
        error("Missing atoms from forcefield.")
    end

    # Bool's of whether to compute guest-host and/or guest-guest electrostatic energies
    #   there is no point in going through the computations if all charges are zero!
    const charged_framework = charged(framework, verbose=verbose)
    const charged_molecules = charged(molecule, verbose=verbose)

    # define Ewald summation params
    #  TODO do this automatically with rules!
    const sr_cutoff_r = sqrt(ljforcefield.cutoffradius_squared)

    # pre-compute weights on k-vector contributions to long-rage interactions in
    #   Ewald summation for electrostatics
    #   allocate memory for exp^{i * n * k ⋅ r}
    eparams, kvectors, eikar, eikbr, eikcr = setup_Ewald_sum(sr_cutoff_r, simulation_box,
                        verbose=verbose & (charged_framework || charged_molecules), ϵ=ewald_precision)

    # initiate system energy to which we increment when MC moves are accepted
    system_energy = PotentialEnergy(0.0, 0.0, 0.0, 0.0)
    # if we don't start with an emtpy framework, compute energy of starting configuration
    #  (n=0 corresponds to zero energy)
    if length(molecules) != 0
        # ensure molecule template matches species of starting molecules.
        assert(all([m.species == molecule_template.species for m in molecules]))

        system_energy.vdw_gh = total_guest_host_vdw_energy(framework, molecules, ljforcefield, repfactors)
        system_energy.vdw_gg = total_guest_guest_vdw_energy(molecules, ljforcefield, simulation_box)
        system_energy.electro_gh = total_electrostatic_potential_energy(framework, molecules,
                                            repfactors, eparams, kvectors, eikar, eikbr, eikcr)
        system_energy.electro_gg = total_electrostatic_potential_energy(molecules,
                                            eparams, kvectors, eikar, eikbr, eikcr)
    end

    # initiate GCMC statistics collected during *entire* sampling period
    gcmc_stats = GCMCstats()
    # break simulation into `N_BLOCKS` blocks to gauge convergence
    gcmc_stats_this_block = GCMCstats()
    current_block = 1
    const n_cycles_per_block = floor(Int, n_sample_cycles / N_BLOCKS)

    markov_counts = MarkovCounts(zeros(Int, length(PROPOSAL_ENCODINGS)),
                                 zeros(Int, length(PROPOSAL_ENCODINGS)))

    # (n_burn_cycles + n_sample_cycles) is number of outer cycles.
    #   for each outer cycle, peform max(20, # molecules in the system) MC proposals.
    markov_chain_time = 0
    for outer_cycle = 1:(n_burn_cycles + n_sample_cycles), inner_cycle = 1:max(20, length(molecules))
        markov_chain_time += 1

        # choose proposed move randomly; keep track of proposals
        which_move = sample(1:N_PROPOSAL_TYPES, PROBABILITIES_OF_MC_PROPOSALS) # StatsBase.jl
        markov_counts.n_proposed[which_move] += 1

        if which_move == INSERTION
            insert_molecule!(molecules, simulation_box, molecule_template)

            # compute the potential energy of the inserted molecule
            energy = potential_energy(length(molecules), molecules, framework, ljforcefield,
                                      simulation_box, repfactors, eparams,
                                      kvectors, eikar, eikbr, eikcr, charged_molecules, charged_framework)

            # Metropolis Hastings Acceptance for Insertion
            if rand() < fugacity * simulation_box.Ω / (length(molecules) * KB *
                    temperature) * exp(-sum(energy) / temperature)
                # accept the move, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                system_energy += energy
            else
                # reject the move, remove the inserted molecule
                pop!(molecules)
            end
        elseif (which_move == DELETION) && (length(molecules) != 0)
            # propose which molecule to delete
            molecule_id = rand(1:length(molecules))

            # compute the potential energy of the molecule we propose to delete
            energy = potential_energy(molecule_id, molecules, framework, ljforcefield,
                                      simulation_box, repfactors, eparams,
                                      kvectors, eikar, eikbr, eikcr, charged_molecules, charged_framework)

            # Metropolis Hastings Acceptance for Deletion
            if rand() < length(molecules) * KB * temperature / (fugacity *
                    simulation_box.Ω) * exp(sum(energy) / temperature)
                # accept the deletion, delete molecule, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                delete_molecule!(molecule_id, molecules)

                system_energy -= energy
            end
        elseif (which_move == TRANSLATION) && (length(molecules) != 0)
            # propose which molecule whose coordinates we should perturb
            molecule_id = rand(1:length(molecules))

            # energy of the molecule before it was translated
            energy_old = potential_energy(molecule_id, molecules, framework, ljforcefield,
                                      simulation_box, repfactors, eparams,
                                      kvectors, eikar, eikbr, eikcr, charged_molecules, charged_framework)

            old_molecule = translate_molecule!(molecules[molecule_id], simulation_box)

            # energy of the molecule after it is translated
            energy_new = potential_energy(molecule_id, molecules, framework, ljforcefield,
                                      simulation_box, repfactors, eparams,
                                      kvectors, eikar, eikbr, eikcr, charged_molecules, charged_framework)

            # Metropolis Hastings Acceptance for translation
            if rand() < exp(-(sum(energy_new) - sum(energy_old)) / temperature)
                # accept the move, adjust current energy
                markov_counts.n_accepted[which_move] += 1

                system_energy += energy_new - energy_old
            else
                # reject the move, put back the old molecule
                molecules[molecule_id] = deepcopy(old_molecule)
            end
        elseif (which_move == REINSERTION) && (length(molecules) != 0)
            # propose which molecule to re-insert
            molecule_id = rand(1:length(molecules))

            # compute the potential energy of the molecule we propose to re-insert
            energy_old = potential_energy(molecule_id, molecules, framework, ljforcefield,
                                         simulation_box, repfactors, eparams,
                                         kvectors, eikar, eikbr, eikcr, charged_molecules,
                                         charged_framework)

            # reinsert molecule; store old configuration of the molecule in case proposal is rejected
            old_molecule = reinsert_molecule!(molecules[molecule_id], simulation_box)

            # compute the potential energy of the molecule in its new configuraiton
            energy_new = potential_energy(molecule_id, molecules, framework, ljforcefield,
                                         simulation_box, repfactors, eparams,
                                         kvectors, eikar, eikbr, eikcr, charged_molecules,
                                         charged_framework)

            # Metropolis Hastings Acceptance for reinsertion
            if rand() < exp(-(sum(energy_new) - sum(energy_old)) / temperature)
                # accept the move, adjust current energy
                markov_counts.n_accepted[which_move] += 1

                system_energy += energy_new - energy_old
            else
                # reject the move, put back old molecule
                molecules[molecule_id] = deepcopy(old_molecule)
            end
        end # which move the code executes

        # TODO remove after testing.
        for molecule in molecules
            @assert(! outside_box(molecule, simulation_box), "molecule outside box!")
        end

        # if we're in the production MC cycles. i.e. we've done all burn cycles...
        if outer_cycle > n_burn_cycles
            # take a sample.
            if markov_chain_time % sample_frequency == 0
                gcmc_stats_this_block.n_samples += 1

                gcmc_stats_this_block.n += length(molecules)
                gcmc_stats_this_block.n² += length(molecules) ^ 2

                gcmc_stats_this_block.U += system_energy
                gcmc_stats_this_block.U² += square(system_energy)

                gcmc_stats_this_block.Un += sum(system_energy) * length(molecules)
            end

            # print block statistics if first inner cycle of the right outer cycle.
            if (inner_cycle == 1) && ((outer_cycle - n_burn_cycles) % n_cycles_per_block == 0)
                # keep track of stats over entire simulation.
                gcmc_stats = gcmc_stats + gcmc_stats_this_block
                # print results
                if verbose
                    print_with_color(:yellow, @sprintf("\tBlock  %d/%d statistics:\n", current_block, N_BLOCKS))
                    print(gcmc_stats_this_block)
                end
                # reset block stats
                current_block += 1
                gcmc_stats_this_block = GCMCstats()
            end
        end # end sampling code
    end # finished markov chain proposal moves

    # in case there are leftover samples b/c blocks did not divide cycles evenly
    gcmc_stats = gcmc_stats + gcmc_stats_this_block

    # compute total energy, compare to `current_energy*` variables where were incremented
    system_energy_end = PotentialEnergy(0.0, 0.0, 0.0, 0.0)
    system_energy_end.vdw_gh = total_guest_host_vdw_energy(framework, molecules, ljforcefield, repfactors)
    system_energy_end.vdw_gg = total_guest_guest_vdw_energy(molecules, ljforcefield, simulation_box)
    system_energy_end.electro_gh = total_electrostatic_potential_energy(framework, molecules,
                                        repfactors, eparams, kvectors, eikar, eikbr, eikcr)
    system_energy_end.electro_gg = total_electrostatic_potential_energy(molecules,
                                        eparams, kvectors, eikar, eikbr, eikcr)

    # see Energetics_Util.jl for this function, overloaded isapprox to print mismatch
    if ! isapprox(system_energy, system_energy_end, verbose=true, atol=0.01)
        error("energy incremented improperly during simulation...")
    end

    @assert(markov_chain_time == sum(markov_counts.n_proposed))
    toc()

    results = Dict{String, Any}()
    results["crystal"] = framework.name
    results["adsorbate"] = molecule.species
    results["forcefield"] = ljforcefield.name
    results["fugacity (Pa)"] = fugacity
    results["temperature (K)"] = temperature
    results["repfactors"] = repfactors

    results["# sample cycles"] = n_sample_cycles
    results["# burn cycles"] = n_burn_cycles
    results["# samples"] = gcmc_stats.n_samples

    # number of adsorbed molecules
    results["⟨N⟩ (molecules)"] = gcmc_stats.n / gcmc_stats.n_samples
    results["⟨N⟩ (molecules/unit cell)"] = results["⟨N⟩ (molecules)"] /
        (repfactors[1] * repfactors[2] * repfactors[3])
    # (molecules/unit cell) * (mol/6.02 * 10^23 molecules) * (1000 mmol/mol) *
    #    (unit cell/framework amu) * (amu/ 1.66054 * 10^-24)
    results["⟨N⟩ (mmol/g)"] = results["⟨N⟩ (molecules/unit cell)"] * 1000 /
        (6.022140857e23 * molecular_weight(framework) * 1.66054e-24)
    results["var(N)"] = (gcmc_stats.n² / gcmc_stats.n_samples) -
        (results["⟨N⟩ (molecules)"] ^ 2)

    # potential energies
    results["⟨U_gg, vdw⟩ (K)"]     = gcmc_stats.U.vdw_gg     / gcmc_stats.n_samples
    results["⟨U_gg, electro⟩ (K)"] = gcmc_stats.U.electro_gg / gcmc_stats.n_samples
    results["⟨U_gh, vdw⟩ (K)"]     = gcmc_stats.U.vdw_gh     / gcmc_stats.n_samples
    results["⟨U_gh, electro⟩ (K)"] = gcmc_stats.U.electro_gh / gcmc_stats.n_samples

    results["⟨U⟩ (K)"] = sum(gcmc_stats.U) / gcmc_stats.n_samples

    results["var(U_gg, vdw)"] = (gcmc_stats.U².vdw_gg / gcmc_stats.n_samples) - results["⟨U_gg, vdw⟩ (K)"] ^ 2
    results["var(U_gh, vdw)"] = (gcmc_stats.U².vdw_gh / gcmc_stats.n_samples) - results["⟨U_gh, vdw⟩ (K)"] ^ 2
    results["var(U_gg, electro)"] = (gcmc_stats.U².electro_gg / gcmc_stats.n_samples) - results["⟨U_gg, electro⟩ (K)"] ^ 2
    results["var(U_gh, electro)"] = (gcmc_stats.U².electro_gh / gcmc_stats.n_samples) - results["⟨U_gh, electro⟩ (K)"] ^ 2

    # heat of adsorption
    results["Q_st (K)"] = temperature - (gcmc_stats.Un / gcmc_stats.n_samples - results["⟨U⟩ (K)"] * results["⟨N⟩ (molecules)"]) / results["var(N)"]

    # Markov stats
    for (proposal_id, proposal_description) in PROPOSAL_ENCODINGS
        results[@sprintf("Total # %s proposals", proposal_description)] = markov_counts.n_proposed[proposal_id]
        results[@sprintf("Fraction of %s proposals accepted", proposal_description)] = markov_counts.n_accepted[proposal_id] / markov_counts.n_proposed[proposal_id]
    end

    if verbose
        print_results(results, print_title=false)
    end

    return results, molecules # summary of statistics and ending configuration of molecules
end # gcmc_simulation

"""
Determine the name of files saved during the GCMC simulation, be molecule positions or results.
"""
function root_save_filename(framework::Framework,
                            molecule::Molecule,
                            ljforcefield::LennardJonesForceField,
                            temperature::Float64,
                            fugacity::Float64,
                            n_burn_cycles::Int,
                            n_sample_cycles::Int)
        frameworkname = split(framework.name, ".")[1] # remove file extension
        forcefieldname = split(ljforcefield.name, ".")[1] # remove file extension
        return @sprintf("gcmc_%s_%s_T%f_fug%f_%s_%dburn_%dsample", frameworkname,
                    molecule.species, temperature, fugacity, forcefieldname,
                    n_burn_cycles, n_sample_cycles)
end

function print_results(results::Dict; print_title::Bool=true)
    if print_title
        # already print in GCMC tests...
        @printf("GCMC simulation of %s in %s at %f K and %f Pa = %f bar fugacity.\n\n",
                results["adsorbate"], results["crystal"], results["temperature (K)"],
                results["fugacity (Pa)"], results["fugacity (Pa)"] / 100000.0)
    end

    @printf("Unit cell replication factors: %d %d %d\n\n", results["repfactors"][1],
                                                         results["repfactors"][2],
                                                         results["repfactors"][3])
    # Markov stats
    for (proposal_id, proposal_description) in PROPOSAL_ENCODINGS
        for key in [@sprintf("Total # %s proposals", proposal_description),
                    @sprintf("Fraction of %s proposals accepted", proposal_description)]
            println(key * ": ", results[key])
        end
    end

    println("")
    for key in ["# sample cycles", "# burn cycles", "# samples"]
        println(key * ": ", results[key])
    end


    println("")
    for key in ["⟨N⟩ (molecules)", "var(N)", "⟨N⟩ (molecules/unit cell)", "⟨N⟩ (mmol/g)",
                "⟨U_gg, vdw⟩ (K)", "⟨U_gh, vdw⟩ (K)", "⟨U_gg, electro⟩ (K)",
                "⟨U_gh, electro⟩ (K)", "⟨U⟩ (K)"]
        println(key * ": ", results[key]) # for spacing
        if key == "⟨N⟩ (mmol/g)"
            println("")
        end
    end

    @printf("\nQ_st (K) = %f = %f kJ/mol\n", results["Q_st (K)"], results["Q_st (K)"] * 8.314 / 1000.0)
    return
end

function pretty_print(adsorbate::Symbol, frameworkname::String, temperature::Float64, fugacity::Float64)
    print("Simulating adsorption of ")
    print_with_color(:green, adsorbate)
    print(" in ")
    print_with_color(:green, frameworkname)
    print(" at ")
    print_with_color(:green, @sprintf("%f K", temperature))
    print(" and ")
    print_with_color(:green, @sprintf("%f Pa", fugacity))
    println(" (fugacity).")
end
