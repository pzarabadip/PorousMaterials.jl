jobs_to_run = Dict("zif71_bogus_charges" => Dict("gases" => ["CO2EPM2"],
                                                 "temperatures" => [298.0],
                                                 "pressures" => vcat(collect(linspace(0.0, 1.0, 11))[2:end-1],
                                                                     collect(linspace(0.0, 20.0, 21))[2:end])
                                                ),
                  )
