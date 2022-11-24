"""
The Lodyc Ocean Biogeochemical Simulation Tools for Ecosystem and Resources (LOBSTER) model

Tracers
========
* Nitrates: NO₃ (mmol N/m³)
* Ammonia: NH₄ (mmol N/m³)
* Phytoplankton: P (mmol N/m³)
* Zooplankton: Z (mmol N/m³)
* Small (slow sinking) detritus: D (mmol N/m³)
* Large (fast sinking) detritus: DD (mmol N/m³)
* Small (slow sinking) detritus carbon content: Dᶜ (mmol C/m³)
* Large (fast sinking) detritus carbon content: DDᶜ (mmol C/m³)
* Disolved organic matter: DOM (mmol N/m³)

Optional tracers
===========
* Disolved inorganic carbon: DIC (mmol C/m³)
* Alkalinity: ALK (mmol ⁻/m³)

* Oxygen: OXY (mmol O₂/m³)

Required forcing
===========
* Photosynthetically available radiation: PAR (W/m²)

For optional tracers:
* Temperature: T (ᵒC)
* Salinity: S (‰)
"""

using Oceananigans.Biogeochemistry: AbstractContinuousFormBiogeochemistry, all_fields_present
using Oceananigans.Units
using Oceananigans.Advection: CenteredSecondOrder
using Oceananigans.Fields: Field, TracerFields, CenterField

using OceanBioME.Light: TwoBandPhotosyntheticallyActiveRatiation, update_PAR!, required_PAR_fields, AbstractLightAttenuation
using OceanBioME: setup_velocity_fields

import Oceananigans.Biogeochemistry:
       required_biogeochemical_tracers,
       required_biogeochemical_auxiliary_fields,
       biogeochemical_drift_velocity,
       biogeochemical_advection_scheme,
       update_biogeochemical_state!

"""
    LOBSTER(;grid,
             phytoplankton_preference::FT = 0.5,
             maximum_grazing_rate::FT = 9.26e-6, # 1/s
             grazing_half_saturation::FT = 1.0, # mmol N/m³
             light_half_saturation::FT = 33.0, # W/m² (?)
             nitrate_ammonia_inhibition::FT = 3.0,
             nitrate_half_saturation::FT = 0.7, # mmol N/m³
             ammonia_half_saturation::FT = 0.001, # mmol N/m³
             maximum_phytoplankton_growthrate::FT = 1.21e-5, # 1/s
             zooplankton_assimilation_fraction::FT = 0.7,
             zooplankton_mortality::FT = 2.31e-6, # 1/s/mmol N/m³
             zooplankton_excretion_rate::FT = 5.8e-7, # 1/s
             phytoplankon_mortality::FT = 5.8e-7, # 1/s
             small_detritus_remineralisation_rate::FT = 5.88e-7, # 1/s
             large_detritus_remineralisation_rate::FT = 5.88e-7, # 1/s
             phytoplankton_exudation_fraction::FT = 0.05,
             nitrifcaiton_rate::FT = 5.8e-7, # 1/s
             ammonia_fraction_of_exudate::FT = 0.75, 
             ammonia_fraction_of_excriment::FT = 0.5,
             ammonia_fraction_of_detritus::FT = 0.0,
             phytoplankton_redfield::FT = 6.56, # mol C/mol N
             disolved_organic_redfield::FT = 6.56, # mol C/mol N
             phytoplankton_chlorophyll_ratio::FT = 1.31, # mgChl/mol N
             organic_carbon_calcate_ratio::FT = 0.1, # mol CaCO₃/mol N
             respiraiton_oxygen_nitrogen_ratio::FT = 10.75, # mol O/molN
             nitrifcation_oxygen_nitrogen_ratio::FT = 2.0, # mol O/molN
             slow_sinking_mortality_fraction::FT = 0.5, 
             fast_sinking_mortality_fraction::FT = 0.5,
             disolved_organic_breakdown_rate::FT = 3.86e-7, # 1/s

             light_attenuation_model::AbstractLightAttenuation = TwoBandPhotosyntheticallyActiveRatiation(),
             surface_phytosynthetically_active_radiation::SPAR = (x, y, t) -> 100*max(0.0, cos(t*π/(12hours))),

             carbonates::Bool = false,
             oxygen::Bool = false,

             sinking_velocities = (D = (0.0, 0.0, -3.47e-5), DD = (0.0, 0.0, -200/day)),
             open_bottom::Bool = true,
             advection_schemes::A = NamedTuple{keys(sinking_velocities)}(repeat([CenteredSecondOrder()], 
                                                                         length(sinking_velocities))))

Construct an instance of the LOBSTER ([LOBSTER](@cite)) biogeochemical model.

Keywork Arguments
===================

    - `grid`: (required) the geometry to build the model on, required to calculate sinking
    - `phytoplankton_preference`, ..., `disolved_organic_breakdown_rate`: LOBSTER parameter values
    - `light_attenuation_model`: light attenuation model which integrated the attenuation of available light as an `AbstractLightAttenuation` model
    - `surface_phytosynthetically_active_radiation`: funciton (or array in the future) for the photosynthetically available radiaiton at the surface, should be shape `f(x, y, t)`
    - `carbonates` and `oxygen`: include models for carbonate chemistry and/or oxygen chemistry
    - `sinking_velocities`: named tuple of either scalar `(u, v, w)` constant sinking velocities, or of named tuples of fields (i.e. `(u = XFaceField(...), v = YFaceField(...), w = ZFaceField(...))`) for any tracers which sink
    - `open_bottom`: should the sinking velocity be smoothly brought to zero at the bottom to prevent the tracers leaving the domain
    - `advection_schemes`: named tuple of advection scheme to use for sinking
"""
struct LOBSTER{FT, L, SPAR, B, W, A} <: AbstractContinuousFormBiogeochemistry
    phytoplankton_preference :: FT
    maximum_grazing_rate :: FT
    grazing_half_saturation :: FT
    light_half_saturation :: FT
    nitrate_ammonia_inhibition :: FT
    nitrate_half_saturation :: FT
    ammonia_half_saturation :: FT
    maximum_phytoplankton_growthrate :: FT
    zooplankton_assimilation_fraction :: FT
    zooplankton_mortality :: FT
    zooplankton_excretion_rate :: FT
    phytoplankon_mortality :: FT
    small_detritus_remineralisation_rate :: FT
    large_detritus_remineralisation_rate :: FT
    phytoplankton_exudation_fraction :: FT
    nitrifcaiton_rate :: FT
    ammonia_fraction_of_exudate :: FT
    ammonia_fraction_of_excriment :: FT
    ammonia_fraction_of_detritus :: FT
    phytoplankton_redfield :: FT
    disolved_organic_redfield :: FT
    phytoplankton_chlorophyll_ratio :: FT
    organic_carbon_calcate_ratio :: FT
    respiraiton_oxygen_nitrogen_ratio :: FT
    nitrifcation_oxygen_nitrogen_ratio :: FT
    slow_sinking_mortality_fraction :: FT
    fast_sinking_mortality_fraction :: FT
    disolved_organic_breakdown_rate :: FT

    light_attenuation_model :: AbstractLightAttenuation
    surface_phytosynthetically_active_radiation :: SPAR

    optionals :: B

    sinking_velocities :: W
    advection_schemes :: A

    function LOBSTER(;grid,
                      phytoplankton_preference::FT = 0.5,
                      maximum_grazing_rate::FT = 9.26e-6, # 1/s
                      grazing_half_saturation::FT = 1.0, # mmol N/m³
                      light_half_saturation::FT = 33.0, # W/m² (?)
                      nitrate_ammonia_inhibition::FT = 3.0,
                      nitrate_half_saturation::FT = 0.7, # mmol N/m³
                      ammonia_half_saturation::FT = 0.001, # mmol N/m³
                      maximum_phytoplankton_growthrate::FT = 1.21e-5, # 1/s
                      zooplankton_assimilation_fraction::FT = 0.7,
                      zooplankton_mortality::FT = 2.31e-6, # 1/s/mmol N/m³
                      zooplankton_excretion_rate::FT = 5.8e-7, # 1/s
                      phytoplankon_mortality::FT = 5.8e-7, # 1/s
                      small_detritus_remineralisation_rate::FT = 5.88e-7, # 1/s
                      large_detritus_remineralisation_rate::FT = 5.88e-7, # 1/s
                      phytoplankton_exudation_fraction::FT = 0.05,
                      nitrifcaiton_rate::FT = 5.8e-7, # 1/s
                      ammonia_fraction_of_exudate::FT = 0.75, 
                      ammonia_fraction_of_excriment::FT = 0.5,
                      ammonia_fraction_of_detritus::FT = 0.0,
                      phytoplankton_redfield::FT = 6.56, # mol C/mol N
                      disolved_organic_redfield::FT = 6.56, # mol C/mol N
                      phytoplankton_chlorophyll_ratio::FT = 1.31, # mgChl/mol N
                      organic_carbon_calcate_ratio::FT = 0.1, # mol CaCO₃/mol N
                      respiraiton_oxygen_nitrogen_ratio::FT = 10.75, # mol O/molN
                      nitrifcation_oxygen_nitrogen_ratio::FT = 2.0, # mol O/molN
                      slow_sinking_mortality_fraction::FT = 0.5, 
                      fast_sinking_mortality_fraction::FT = 0.5,
                      disolved_organic_breakdown_rate::FT = 3.86e-7, # 1/s

                      light_attenuation_model::AbstractLightAttenuation = TwoBandPhotosyntheticallyActiveRatiation(), # user could specify some other model separatly (I think)
                      surface_phytosynthetically_active_radiation::SPAR = (x, y, t) -> 100*max(0.0, cos(t*π/(12hours))),

                      carbonates::Bool = false,
                      oxygen::Bool = false,
                
                      sinking_velocities = (D = (0.0, 0.0, -3.47e-5), DD = (0.0, 0.0, -200/day)),
                      open_bottom::Bool = true,
                      advection_schemes::A = NamedTuple{keys(sinking_velocities)}(repeat([CenteredSecondOrder()], 
                                                                                    length(sinking_velocities)))) where {FT, AbstractLightAttenuation, SPAR, A}

        

        sinking_velocities = setup_velocity_fields(sinking_velocities, grid, open_bottom)
        W = typeof(sinking_velocities)
        optionals = Val((carbonates, oxygen))
        B = typeof(optionals)

        return new{FT, AbstractLightAttenuation, SPAR, B, W, A}(phytoplankton_preference,
                                                                maximum_grazing_rate,
                                                                grazing_half_saturation,
                                                                light_half_saturation,
                                                                nitrate_ammonia_inhibition,
                                                                nitrate_half_saturation,
                                                                ammonia_half_saturation,
                                                                maximum_phytoplankton_growthrate,
                                                                zooplankton_assimilation_fraction,
                                                                zooplankton_mortality,
                                                                zooplankton_excretion_rate,
                                                                phytoplankon_mortality,
                                                                small_detritus_remineralisation_rate,
                                                                large_detritus_remineralisation_rate,
                                                                phytoplankton_exudation_fraction,
                                                                nitrifcaiton_rate,
                                                                ammonia_fraction_of_exudate,
                                                                ammonia_fraction_of_excriment,
                                                                ammonia_fraction_of_detritus,
                                                                phytoplankton_redfield,
                                                                disolved_organic_redfield,
                                                                phytoplankton_chlorophyll_ratio,
                                                                organic_carbon_calcate_ratio,
                                                                respiraiton_oxygen_nitrogen_ratio,
                                                                nitrifcation_oxygen_nitrogen_ratio,
                                                                slow_sinking_mortality_fraction,
                                                                fast_sinking_mortality_fraction,
                                                                disolved_organic_breakdown_rate,

                                                                light_attenuation_model,
                                                                surface_phytosynthetically_active_radiation,

                                                                optionals,
                                                            
                                                                sinking_velocities,
                                                                advection_schemes)
    end
end

@inline required_biogeochemical_tracers(::LOBSTER{<:Any, <:Any, <:Any, <:Val{(false, false)}, <:Any, <:Any}) = (:NO₃, :NH₄, :P, :Z, :D, :DD, :Dᶜ, :DDᶜ, :DOM)
@inline required_biogeochemical_tracers(::LOBSTER{<:Any, <:Any, <:Any, <:Val{(true, false)}, <:Any, <:Any}) = (:NO₃, :NH₄, :P, :Z, :D, :DD, :Dᶜ, :DDᶜ, :DOM, :DIC, :ALK)
@inline required_biogeochemical_tracers(::LOBSTER{<:Any, <:Any, <:Any, <:Val{(false, true)}, <:Any, <:Any}) = (:NO₃, :NH₄, :P, :Z, :D, :DD, :Dᶜ, :DDᶜ, :DOM, :OXY)
@inline required_biogeochemical_tracers(::LOBSTER{<:Any, <:Any, <:Any, <:Val{(true, true)}, <:Any, <:Any}) = (:NO₃, :NH₄, :P, :Z, :D, :DD, :Dᶜ, :DDᶜ, :DOM, :DIC, :ALK, :OXY)

@inline required_biogeochemical_auxiliary_fields(model::LOBSTER) = required_PAR_fields(model.light_attenuation_model)

const small_detritus = Union{Val{:D}, Val{:Dᶜ}}
const large_detritus = Union{Val{:DD}, Val{:DDᶜ}}

# not sure this is the most computationally efficient method
@inline biogeochemical_drift_velocity(bgc::LOBSTER, ::Val{:Dᶜ}) = biogeochemical_drift_velocity(bgc, Val(:D))
@inline biogeochemical_drift_velocity(bgc::LOBSTER, ::Val{:DDᶜ}) = biogeochemical_drift_velocity(bgc, Val(:DD))

@inline function biogeochemical_drift_velocity(bgc::LOBSTER, ::Val{tracer_name}) where tracer_name
    if tracer_name in keys(bgc.sinking_velocities)
        return bgc.sinking_velocities[tracer_name]
    else
        return nothing
    end
end

@inline biogeochemical_advection_scheme(bgc::LOBSTER, ::Val{:Dᶜ}) = biogeochemical_advection_scheme(bgc, Val(:D))
@inline biogeochemical_advection_scheme(bgc::LOBSTER, ::Val{:DDᶜ}) = biogeochemical_advection_scheme(bgc, Val(:DD))

@inline function biogeochemical_advection_scheme(bgc::LOBSTER, ::Val{tracer_name}) where tracer_name
    if tracer_name in keys(bgc.sinking_velocities)
        return bgc.advection_schemes[tracer_name]
    else
        return nothing
    end
end

function update_biogeochemical_state!(bgc::LOBSTER, model)
    update_PAR!(model, bgc.light_attenuation_model, bgc.surface_phytosynthetically_active_radiation)
end

include("core.jl")
include("carbonate_chemistry.jl")
include("oxygen_chemistry.jl")

include("fallbacks.jl")
