"""
    DimGroupByArray <: AbstractDimArray

`DimGroupByArray` is essentially a `DimArray` but holding
the results of a `groupby` operation.

Its dimensions are the sorted results of the grouping functions
used in `groupby`.

This wrapper allows for specialisations on later broadcast or
reducing operations, e.g. for chunk reading with DiskArrays.jl,
because we know the data originates from a single array.
"""
struct DimGroupByArray{T,N,D<:Tuple,R<:Tuple,A<:AbstractArray{T,N},Na,Me} <: AbstractDimArray{T,N,D,A}
    data::A
    dims::D
    refdims::R
    name::Na
    metadata::Me
    function DimGroupByArray(
        data::A, dims::D, refdims::R, name::Na, metadata::Me
    ) where {D<:Tuple,R<:Tuple,A<:AbstractArray{T,N},Na,Me} where {T,N}
        checkdims(data, dims)
        new{T,N,D,R,A,Na,Me}(data, dims, refdims, name, metadata)
    end
end
function DimGroupByArray(data::AbstractArray, dims::Union{Tuple,NamedTuple};
    refdims=(), name=NoName(), metadata=NoMetadata()
)
    DimGroupByArray(data, format(dims, data), refdims, name, metadata)
end
@inline function rebuild(
    A::DimGroupByArray, data::AbstractArray, dims::Tuple, refdims::Tuple, name, metadata
)
    if eltype(data) <: Union{AbstractDimArray,AbstractDimStack}
        # We have DimArrays or DimStacks. Rebuild as a DimGroupArray
        DimGroupByArray(data, dims, refdims, name, metadata)
    else
        # Some other values. Rebuild as a reguilar DimArray
        dimconstructor(dims)(data, dims, refdims, name, metadata)
    end
end
@inline function rebuild(A::DimGroupByArray;
    data=parent(A), dims=dims(A), refdims=refdims(A), name=name(A), metadata=metadata(A)
)
    rebuild(A, data, dims, refdims, name, metadata) # Rebuild as a reguilar DimArray
end

function Base.summary(io::IO, A::DimGroupByArray{T,N}) where {T,N}
    print_ndims(io, size(A))
    print(io, string(nameof(typeof(A)), "{$(nameof(T)),$N}"))
end

function show_after(io::IO, mime, A::DimGroupByArray; maxlen=0)
    _, width = displaysize(io)
    sorteddims = (dims(A)..., otherdims(first(A), dims(A))...)
    colordims = dims(map(rebuild, sorteddims, ntuple(dimcolors, Val(length(sorteddims)))), dims(first(A)))
    colors = collect(map(val, colordims))
    print_dims_block(io, mime, basedims(first(A)); width, maxlen, label="group dims", colors)
    length(A) > 0 || return nothing
    A1 = map(x -> DimSummariser(x, colors), A)
    show_after(io, mime, A1; maxlen)
    return nothing
end

mutable struct DimSummariser{T}
    obj::T
    colors::Vector{Int}
end
function Base.show(io::IO, s::DimSummariser)
    print_ndims(io, size(s.obj); colors=s.colors)
    print(io, string(nameof(typeof(s.obj))))
end
Base.alignment(io::IO, s::DimSummariser) = (textwidth(sprint(show, s)), 0)


abstract type AbstractBins <: Function end

(bins::AbstractBins)(x) = bins.f(x)

"""
    Bins(f, bins; pad)
    Bins(bins; pad)

Specify bins to reduce groups after applying function `f`.

- `f` a grouping function of the lookup values, by default `identity`.
- `bins`:
   * an `Integer` will divide the group values into equally spaced sections.
   * an `AbstractArray` of values will be treated as exact
       matches for the return value of `f`. For example, `1:3` will create 3 bins - 1, 2, 3.
   * an `AbstractArray` of `IntervalSets.Interval` can be used to
       explictly define the intervals. Overlapping intervals have undefined behaviour.

## Keywords

- `pad`: fraction of the total interval to pad at each end when `Bins` contains an
   `Integer`. This avoids losing the edge values. Note this is a messy solution -
   it will often be prefereble to manually specify a `Vector` of chosen `Interval`s
   rather than relying on passing an `Integer` and `pad`.

When the return value of `f` is a tuple, binning is applied to the _last_ value of the tuples.
"""
struct Bins{F<:Callable,B<:Union{Integer,AbstractVector,Tuple},L,P} <: AbstractBins
    f::F
    bins::B
    labels::L
    pad::P
end
Bins(bins; labels=nothing, pad=0.001) = Bins(identity, bins, labels, pad)
Bins(f, bins; labels=nothing, pad=0.001) = Bins(f, bins, labels, pad)

Base.show(io::IO, bins::Bins) = println(io, nameof(typeof(bins)), "(", bins.f, ", ", bins.bins, ")")

abstract type AbstractCyclicBins end
struct CyclicBins{F,C,Sta,Ste,L} <: AbstractBins
    f::F
    cycle::C
    start::Sta
    step::Ste
    labels::L
end
CyclicBins(f; cycle, step, start=1, labels=nothing) = CyclicBins(f, cycle, start, step, labels)

Base.show(io::IO, bins::CyclicBins) = 
println(io, nameof(typeof(bins)), "(", bins.f, "; ", join(map(k -> "$k=$(getproperty(bins, k))", (:cycle, :step, :start)), ", "), ")")

yearhour(x) = year(x), hour(x)

season(; start=January, kw...) = months(3; start, kw...)
months(step; start=January, labels=Dict(1:12 .=> monthabbr.(1:12))) = CyclicBins(month; cycle=12, step, start, labels)
hours(step; start=0, labels=nothing) = CyclicBins(hour; cycle=24, step, start, labels)
yearhours(step; start=0, labels=nothing) = CyclicBins(yearhour; cycle=24, step, start, labels)
yeardays(step; start=1, labels=nothing) = CyclicBins(dayofyear; cycle=daysinyear, step, start, labels)
monthdays(step; start=1, labels=nothing) = CyclicBins(dayofmonth; cycle=daysinmonth, step, start, labels)

"""
    groupby(A::Union{AbstractDimArray,AbstractDimStack}, dims::Pair...)
    groupby(A::Union{AbstractDimArray,AbstractDimStack}, dims::Dimension{<:Callable}...)

Group `A` by grouping functions or [`Bins`](@ref) over multiple dimensions.

## Arguments

- `A`: any `AbstractDimArray` or `AbsractDimStack`.
- `dims`: `Pair`s such as `groups = groupby(A, :dimname => groupingfunction)` or wrapped
    [`Dimension`](@ref)s like `groups = groupby(A, DimType(groupingfunction))`. Instead of
    a grouping function [`Bins`](@ref) can be used to specify group bins.

## Return value

A [`DimGroupByArray`](@ref) is returned, which is basically a regular `AbstractDimArray`
but holding the grouped `AbstractDimArray` or `AbstractDimStrack`. Its `dims`
hold the sorted values returned by the grouping function/s.

Base julia and package methods work on `DimGroupByArray` as for any other
`AbstractArray` of `AbstractArray`.

It is common to broadcast or `map` a reducing function over groups,
such as `mean` or `sum`, like `mean.(groups)` or `map(mean, groups)`.
This will return a regular `DimArray`, or `DimGroupByArray` if `dims`
keyword is used in the reducing function or it otherwise returns an
`AbstractDimArray` or `AbstractDimStack`.

# Example

Group some data along the time dimension:

```julia
julia> using DimensionalData, Dates

julia> A = rand(X(1:0.1:20), Y(1:20), Ti(DateTime(2000):Day(3):DateTime(2003)));

julia> groups = groupby(A, Ti => month) # Group by month
╭────────────────────────────────────────╮
│ 12-element DimGroupByArray{DimArray,1} │
├────────────────────────────────────────┴──────────────────────── dims ┐
  ↓ Ti Sampled{Int64} [1, 2, …, 11, 12] ForwardOrdered Irregular Points
├───────────────────────────────────────────────────────────── metadata ┤
  Dict{Symbol, Any} with 1 entry:
  :groupby => (Ti{typeof(month)}(month),)
├─────────────────────────────────────────────────────────── group dims ┤
  ↓ X, → Y, ↗ Ti
└───────────────────────────────────────────────────────────────────────┘
  1  191×20×32 DimArray
  2  191×20×28 DimArray
  3  191×20×31 DimArray
  4  191×20×30 DimArray
  ⋮
  9  191×20×30 DimArray
 10  191×20×31 DimArray
 11  191×20×30 DimArray
 12  191×20×31 DimArray
```

And take the mean:

```
julia> groupmeans = mean.(groups) # Take the monthly mean
╭────────────────────────────────╮
│ 12-element DimArray{Float64,1} │
├────────────────────────────────┴──────────────────────────────── dims ┐
  ↓ Ti Sampled{Int64} [1, 2, …, 11, 12] ForwardOrdered Irregular Points
├───────────────────────────────────────────────────────────── metadata ┤
  Dict{Symbol, Any} with 1 entry:
  :groupby => (Ti{typeof(month)}(month),)
└───────────────────────────────────────────────────────────────────────┘
  1  0.499943
  2  0.499352
  3  0.499289
  4  0.499899
  ⋮
 10  0.500755
 11  0.498912
 12  0.500352
```

Calculate daily anomalies from the monthly mean. Notice we map a broadcast
`.-` rather than `-`. This is because the size of the arrays to not
match after application of `mean`.

```julia
julia> map(.-, groupby(A, Ti=>month), mean.(groupby(A, Ti=>month), dims=Ti));
```

Or do something else with Y:

```julia
julia> groupmeans = mean.(groupby(A, Ti=>month, Y=>isodd))
╭──────────────────────────╮
│ 12×2 DimArray{Float64,2} │
├──────────────────────────┴─────────────────────────────────────── dims ┐
  ↓ Ti Sampled{Int64} [1, 2, …, 11, 12] ForwardOrdered Irregular Points,
  → Y  Sampled{Bool} [false, true] ForwardOrdered Irregular Points
├──────────────────────────────────────────────────────────────────────── metadata ┐
  Dict{Symbol, Any} with 1 entry:
  :groupby => (Ti{typeof(month)}(month), Y{typeof(isodd)}(isodd))
└──────────────────────────────────────────────────────────────────────────────────┘
  ↓ →  false         true
  1        0.500465     0.499421
  2        0.498681     0.500024
  ⋮
 10        0.500183     0.501327
 11        0.497746     0.500079
 12        0.500287     0.500417
```
"""
DataAPI.groupby(A::DimArrayOrStack, x) = groupby(A, dims(x))
DataAPI.groupby(A::DimArrayOrStack, dimfuncs::Dimension...) = groupby(A, dimfuncs)
function DataAPI.groupby(
    A::DimArrayOrStack, p1::Pair{<:Any,<:Base.Callable}, ps::Pair{<:Any,<:Base.Callable}...;
)
    dims = map((p1, ps...)) do (d, v)
        rebuild(basedims(d), v)
    end
    return groupby(A, dims)
end
function DataAPI.groupby(A::DimArrayOrStack, dimfuncs::DimTuple)
    length(otherdims(dimfuncs, dims(A))) > 0 &&
        Dimensions._extradimserror(otherdims(dimfuncs, dims(A)))

    # Get groups for each dimension
    dim_groups_indices = map(dimfuncs) do d
        _group_indices(dims(A, d), DD.val(d))
    end
    # Separate lookups dims from indices
    group_dims = map(first, dim_groups_indices) 
    indices = map(rebuild, dimfuncs, map(last, dim_groups_indices))

    views = DimViews(A, indices)
    # Put the groupby query in metadata
    meta = map(d -> dim2key(d) => val(d), dimfuncs)
    metadata = Dict{Symbol,Any}(:groupby => length(meta) == 1 ? only(meta) : meta)
    # Return a DimGroupByArray
    return DimGroupByArray(views, format(group_dims, views), (), :groupby, metadata)
end

# Define the groups and find all the indices for values that fall in them
function _group_indices(dim::Dimension, f::Base.Callable; labels=nothing)
    orig_lookup = lookup(dim)
    k1 = f(first(orig_lookup))
    indices_dict = Dict{typeof(k1),Vector{Int}}()
    for (i, x) in enumerate(orig_lookup)
         k = f(x)
         inds = get!(() -> Int[], indices_dict, k)
         push!(inds, i)
    end
    ps = sort!(collect(pairs(indices_dict)))
    group_dim = format(rebuild(dim, _maybe_label(labels, first.(ps))))
    indices = last.(ps)
    return group_dim, indices
end
function _group_indices(dim::Dimension, group_lookup::LookupArray; labels=nothing)
    orig_lookup = lookup(dim)
    indices = map(_ -> Int[], 1:length(group_lookup))
    for (i, v) in enumerate(orig_lookup)
        n = selectindices(group_lookup, Contains(v))
        push!(indices[n], i)
    end
    group_dim = if isnothing(labels)
        rebuild(dim, group_lookup)
    else
        label_lookup = _maybe_label(labels, group_lookup)
        rebuild(dim, label_lookup)
    end
    return group_dim, indices
end
function _group_indices(dim::Dimension, bins::AbstractBins; labels=nothing)
    l = lookup(dim)
    # Apply the function first unless its `identity`
    transformed = bins.f == identity ? parent(l) : map(bins.f, parent(l))
    # Calculate the bin groups
    groups = if eltype(transformed) <: Tuple
        # Get all values of the tuples but the last one and take the union
        outer_groups = union!(map(t -> t[1:end-1], transformed))
        inner_groups = _groups_from(transformed, bins)
        # Combine the groups
        mapreduce(vcat, outer_groups) do og
            map(ig -> (og..., ig), inner_groups)
        end
    else
        _groups_from(transformed, bins)
    end
    group_lookup = lookup(format(rebuild(dim, groups)))
    transformed_lookup = rebuild(dim, transformed)

    # Call the LookupArray version to do the work using selectors
    return _group_indices(transformed_lookup, group_lookup)
end


# Get a vector of intervals for the bins
_groups_from(_, bins::Bins{<:Any,<:AbstractArray}) = bins.bins
function _groups_from(transformed, bins::Bins{<:Any,<:Integer})
    # With an Integer, we calculate evenly-spaced bins from the extreme values
    a, b = extrema(last, transformed)
    # pad a tiny bit so the top open interval includes the top value (xarray also does this)
    b_p = b + (b - a) * bins.pad
    # Create a range
    rng = range(IntervalSets.Interval{:closed,:open}(a, b_p), bins.bins)
    # Return a Vector of Interval{:closed,:open} for the range
    return IntervalSets.Interval{:closed,:open}.(rng, rng .+ step(rng))
end
function _groups_from(_, bins::CyclicBins)
    map(bins.start:bins.step:bins.start+bins.cycle-1) do g
        map(0:bins.step-1) do n
            rem(n + g - 1, bins.cycle) + 1
        end
    end
end

# Return the bin for a value
# function _choose_bin(b::AbstractBins, groups::LookupArray, val)
#     groups[ispoints(groups) ? At(val) : Contains(val)] 
# end
# function _choose_bin(b::AbstractBins, groups, val)
#     i = findfirst(Base.Fix1(_in, val), groups)
#     isnothing(i) && return nothing
#     return groups[i]
# end
# function _choose_bin(b::Bins, groups::AbstractArray{<:Number}, val)
#     i = searchsortedlast(groups, val; by=_by)
#     i >= firstindex(groups) && val in groups[i] || return nothing
#     return groups[i]
# end
# function _choose_bin(b::Bins, groups::AbstractArray{<:Tuple{Vararg{Union{Number,AbstractRange,IntervalSets.Interval}}}}, val::Tuple)
#     @assert length(val) == length(first(groups))
#     i = searchsortedlast(groups, val; by=_by)
#     i >= firstindex(groups) && last(val) in last(groups[i]) || return nothing
#     return groups[i]
# end
# _choose_bin(b::Bins, groups::AbstractArray{<:IntervalSets.Interval}, val::Tuple) = _choose_bin(b::Bins, groups, last(val))
# function _choose_bin(b::Bins, groups::AbstractArray{<:IntervalSets.Interval}, val)
#     i = searchsortedlast(groups, val; by=_by)
#     i >= firstindex(groups) && val in groups[i] || return nothing
#     return groups[i]
# end

_maybe_label(vals) = vals
_maybe_label(f::Function, vals) = f.(vals)
_maybe_label(::Nothing, vals) = vals
function _maybe_label(labels::AbstractArray, vals) 
    @assert length(labels) == length(vals)
    return labels
end
function _maybe_label(labels::Dict, vals) 
    map(vals) do val
        if haskey(labels, val)
            labels[val]
        else
            Symbol(join(map(v -> string(labels[v]), val), '_'))
        end
    end
end

# Helpers
intervals(rng::AbstractRange) = IntervalSets.Interval{:closed,:open}.(rng, rng .+ step(rng))
function intervals(la::LookupArray)
    if ispoints(la)
        rebuild(la; data=(x -> IntervalSets.Interval{:closed,:closed}(x, x)).(la))
    else
        rebuild(la; data=(x -> IntervalSets.Interval{:closed,:open}(x[1], x[2])).(intervalbounds(la)))
    end
end
function intervals(A::AbstractVector{T}; upper::T) where T
    is =  Vector{IntervalSets.Interval{:closed,:open}}(undef, length(A))
    for i in eachindex(A)[1:end-1]
        is[i] = IntervalSets.Interval{:closed,:open}(A[i], A[i + 1])
    end
    is[end] = IntervalSets.Interval{:closed,:open}.(A[end], upper)
    return is
end

ranges(rng::AbstractRange) = map(x -> x:x+step(rng)-1, rng)
ranges(rng::LookupArray{<:AbstractRange}) = rebuild(rng; data=ranges(parent(rng)))