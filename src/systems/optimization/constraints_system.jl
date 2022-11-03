"""
$(TYPEDEF)

A constraint system of equations.

# Fields
$(FIELDS)

# Examples

```julia
@variables x y z
@parameters a b c

cstr = [0 ~ a*(y-x),
       0 ~ x*(b-z)-y,
       0 ~ x*y - c*z
       x^2 + y^2 ≲ 1]
@named ns = ConstraintsSystem(cstr, [x,y,z],[a,b,c])
```
"""
struct ConstraintsSystem <: AbstractTimeIndependentSystem
    """
    tag: a tag for the system. If two system have the same tag, then they are
    structurally identical.
    """
    tag::UInt
    """Vector of equations defining the system."""
    constraints::Vector{Union{Equation, Inequality}}
    """Unknown variables."""
    states::Vector
    """Parameters."""
    ps::Vector
    """Array variables."""
    var_to_name::Any
    """Observed variables."""
    observed::Vector{Equation}
    """
    Jacobian matrix. Note: this field will not be defined until
    [`calculate_jacobian`](@ref) is called on the system.
    """
    jac::RefValue{Any}
    """
    Name: the name of the system. These are required to have unique names.
    """
    name::Symbol
    """
    systems: The internal systems
    """
    systems::Vector{ConstraintsSystem}
    """
    defaults: The default values to use when initial conditions and/or
    parameters are not supplied in `ODEProblem`.
    """
    defaults::Dict
    """
    type: type of the system
    """
    connector_type::Any
    """
    metadata: metadata for the system, to be used by downstream packages.
    """
    metadata::Any
    """
    tearing_state: cache for intermediate tearing state
    """
    tearing_state::Any
    """
    substitutions: substitutions generated by tearing.
    """
    substitutions::Any

    function ConstraintsSystem(tag, constraints, states, ps, var_to_name, observed, jac,
                               name,
                               systems,
                               defaults, connector_type, metadata = nothing,
                               tearing_state = nothing, substitutions = nothing;
                               checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckUnits) > 0
            all_dimensionless([states; ps]) || check_units(constraints)
        end
        new(tag, constraints, states, ps, var_to_name, observed, jac, name, systems,
            defaults,
            connector_type, metadata, tearing_state, substitutions)
    end
end

equations(sys::ConstraintsSystem) = constraints(sys) # needed for Base.show

function ConstraintsSystem(constraints, states, ps;
                           observed = [],
                           name = nothing,
                           default_u0 = Dict(),
                           default_p = Dict(),
                           defaults = _merge(Dict(default_u0), Dict(default_p)),
                           systems = ConstraintsSystem[],
                           connector_type = nothing,
                           continuous_events = nothing, # this argument is only required for ODESystems, but is added here for the constructor to accept it without error
                           discrete_events = nothing,   # this argument is only required for ODESystems, but is added here for the constructor to accept it without error
                           checks = true,
                           metadata = nothing)
    continuous_events === nothing || isempty(continuous_events) ||
        throw(ArgumentError("ConstraintsSystem does not accept `continuous_events`, you provided $continuous_events"))
    discrete_events === nothing || isempty(discrete_events) ||
        throw(ArgumentError("ConstraintsSystem does not accept `discrete_events`, you provided $discrete_events"))

    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))

    cstr = value.(Symbolics.canonical_form.(scalarize(constraints)))
    states′ = value.(scalarize(states))
    ps′ = value.(scalarize(ps))

    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn("`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
                     :ConstraintsSystem, force = true)
    end
    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end

    jac = RefValue{Any}(EMPTY_JAC)
    defaults = todict(defaults)
    defaults = Dict(value(k) => value(v) for (k, v) in pairs(defaults))

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, states′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    ConstraintsSystem(Threads.atomic_add!(SYSTEM_COUNT, UInt(1)),
                      cstr, states, ps, var_to_name, observed, jac, name, systems,
                      defaults,
                      connector_type, metadata, checks = checks)
end

function calculate_jacobian(sys::ConstraintsSystem; sparse = false, simplify = false)
    cache = get_jac(sys)[]
    if cache isa Tuple && cache[2] == (sparse, simplify)
        return cache[1]
    end

    lhss = generate_canonical_form_lhss(sys)
    vals = [dv for dv in states(sys)]
    if sparse
        jac = sparsejacobian(lhss, vals, simplify = simplify)
    else
        jac = jacobian(lhss, vals, simplify = simplify)
    end
    get_jac(sys)[] = jac, (sparse, simplify)
    return jac
end

function generate_jacobian(sys::ConstraintsSystem, vs = states(sys), ps = parameters(sys);
                           sparse = false, simplify = false, kwargs...)
    jac = calculate_jacobian(sys, sparse = sparse, simplify = simplify)
    return build_function(jac, vs, ps; kwargs...)
end

function calculate_hessian(sys::ConstraintsSystem; sparse = false, simplify = false)
    lhss = generate_canonical_form_lhss(sys)
    vals = [dv for dv in states(sys)]
    if sparse
        hess = [sparsehessian(lhs, vals, simplify = simplify) for lhs in lhss]
    else
        hess = [hessian(lhs, vals, simplify = simplify) for lhs in lhss]
    end
    return hess
end

function generate_hessian(sys::ConstraintsSystem, vs = states(sys), ps = parameters(sys);
                          sparse = false, simplify = false, kwargs...)
    hess = calculate_hessian(sys, sparse = sparse, simplify = simplify)
    return build_function(hess, vs, ps; kwargs...)
end

function generate_function(sys::ConstraintsSystem, dvs = states(sys), ps = parameters(sys);
                           kwargs...)
    lhss = generate_canonical_form_lhss(sys)
    pre, sol_states = get_substitutions_and_solved_states(sys)

    func = build_function(lhss, value.(dvs), value.(ps); postprocess_fbody = pre,
                          states = sol_states, kwargs...)

    cstr = constraints(sys)
    lcons = fill(-Inf, length(cstr))
    ucons = zeros(length(cstr))
    lcons[findall(Base.Fix2(isa, Equation), cstr)] .= 0.0

    return func, lcons, ucons
end

function jacobian_sparsity(sys::ConstraintsSystem)
    lhss = generate_canonical_form_lhss(sys)
    jacobian_sparsity(lhss, states(sys))
end

function hessian_sparsity(sys::ConstraintsSystem)
    lhss = generate_canonical_form_lhss(sys)
    [hessian_sparsity(eq, states(sys)) for eq in lhss]
end

"""
Convert the system of equalities and inequalities into a canonical form:
h(x) = 0
g(x) <= 0
"""
function generate_canonical_form_lhss(sys)
    lhss = subs_constants([Symbolics.canonical_form(eq).lhs for eq in constraints(sys)])
end

function get_cmap(sys::ConstraintsSystem)
    #Inject substitutions for constants => values
    cs = collect_constants([get_constraints(sys); get_observed(sys)]) #ctrls? what else?
    if !empty_substitutions(sys)
        cs = [cs; collect_constants(get_substitutions(sys).subs)]
    end
    # Swap constants for their values
    cmap = map(x -> x ~ getdefault(x), cs)
    return cmap, cs
end