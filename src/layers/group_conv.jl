"""
    EEquivGraphConv(in_dim=>out_dim, pos_dim, edge_dim; init=glorot_uniform)

E(n)-equivariant graph neural network layer.

# Arguments

- `in_dim::Int`: node feature dimension. Data is assumed to be of the form [feature; coordinate], so `in_dim` must strictly be less than the dimension of the input vectors.
- `out_dim`: the output of the layer will have dimension `out_dim` + (dimension of input vector - `in_dim`).
- `pos_dim::Int`: dimension of positional encoding.
- `edge_dim::Int`: dimension of edge feature.
- `init`: neural network initialization function, should be compatible with `Flux.Dense`.

# Examples

```jldoctest
julia> in_dim, int_dim, out_dim = 3,6,5
(3, 5, 5)

julia> egnn = EEquivGraphConv(in_dim, int_dim, out_dim)
EEquivGraphConv{Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}, Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}, Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}}(Dense(8 => 5), Dense(5 => 1), Dense(8 => 5), 3, 5, 5)

julia> m_len = 2*in_dim + 2
8

julia> nn_edge = Flux.Dense(m_len, int_dim)
Dense(8 => 5)       # 45 parameters

julia> nn_x = Flux.Dense(int_dim, 1)
Dense(5 => 1)       # 6 parameters

julia> nn_h = Flux.Dense(in_dim + int_dim, out_dim)
Dense(8 => 5)       # 45 parameters

julia> egnn = EEquivGraphConv(in_dim, nn_edge, nn_x, nn_h)
EEquivGraphConv{Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}, Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}, Dense{typeof(identity), Matrix{Float32}, Vector{Float32}}}(Dense(8 => 5), Dense(5 => 1), Dense(8 => 5), 3, 5, 5)
```
"""

struct EEquivGraphConv{X,E,H}
    pe::X
    nn_edge::E
    nn_h::H
end

@functor EEquivGraphConv

Flux.trainable(l::EEquivGraphConv) = (l.pe, l.nn_edge, l.nn_h)

function EEquivGraphConv(ch::Pair{Int,Int}, pos_dim::Int, edge_dim::Int; init=glorot_uniform)
    in_dim, out_dim = ch
    nn_edge = Flux.Dense(2in_dim + edge_dim + 1, out_dim; init=init)
    pe = EEquivGraphPE(out_dim=>pos_dim; init=init)
    nn_h = Flux.Dense(in_dim + out_dim, out_dim; init=init)
    return EEquivGraphConv(pe, nn_edge, nn_h)
end

ϕ_edge(l::EEquivGraphConv, h_i, h_j, dist, a) = l.nn_edge(vcat(h_i, h_j, dist, a))

function message(l::EEquivGraphConv, h_i, h_j, x_i, x_j, e)
    dist = sum(abs2, x_i - x_j; dims=1)
    return ϕ_edge(l, h_i, h_j, dist, e)
end

update(l::EEquivGraphConv, m, h) = l.nn_h(vcat(h, m))

# For variable graph
function(egnn::EEquivGraphConv)(fg::AbstractFeaturedGraph)
    nf = node_feature(fg)
    ef = edge_feature(fg)
    pf = positional_feature(fg)
    GraphSignals.check_num_nodes(fg, nf)
    GraphSignals.check_num_edges(fg, ef)
    _, V, X = propagate(egnn, graph(fg), ef, nf, pf, +)
    return ConcreteFeaturedGraph(fg, nf=V, pf=X)
end

function Base.show(io::IO, l::EEquivGraphConv)
    print(io, "EEquivGraphConv(ϕ_edge=", l.nn_edge)
    print(io, ", ϕ_x=", l.pe.nn)
    print(io, ", ϕ_h=", l.nn_h)
    print(io, ")")
end

function aggregate_neighbors(::EEquivGraphConv, el::NamedTuple, aggr, E)
    batch_size = size(E)[end]
    dstsize = (size(E, 1), el.N, batch_size)
    xs = batched_index(el.xs, batch_size)
    return _scatter(aggr, E, xs, dstsize)
end

aggregate_neighbors(::EEquivGraphConv, el::NamedTuple, aggr, E::AbstractMatrix) = _scatter(aggr, E, el.xs)

@inline aggregate_neighbors(::EEquivGraphConv, ::NamedTuple, ::Nothing, E) = nothing
@inline aggregate_neighbors(::EEquivGraphConv, ::NamedTuple, ::Nothing, ::AbstractMatrix) = nothing

function propagate(l::EEquivGraphConv, sg::SparseGraph, E, V, X, aggr)
    el = to_namedtuple(sg)
    return propagate(l, el, E, V, X, aggr)
end

function propagate(l::EEquivGraphConv, el::NamedTuple, E, V, X, aggr)
    E = message(
        l, _gather(V, el.xs), _gather(V, el.nbrs),
        _gather(X, el.xs), _gather(X, el.nbrs),
        _gather(E, el.es)
        )
    X = positional_encode(l.pe, el, X, E)
    Ē = aggregate_neighbors(l, el, aggr, E)
    V = update(l, Ē, V)
    return E, V, X
end
