a = [1 2; 3 4]
dimz = (X((143, 145)), Y((-38, -36)))
da = DimensionalArray(a, dimz)

@testset "getindex for single integers returns values" begin
    @test da[X(1), Y(2)] == 2
    @test da[X(2), Y(2)] == 4
end

@testset "getindex returns DimensionArray slices with the right dimensions" begin
    a = da[X(1:2), Y(1)]
    @test a == [1, 3]
    @test typeof(a) <: DimensionalArray{Int,1}
    @test dims(a) == (X(LinRange(143.0, 145.0, 2); grid=RegularGrid(;span=2.0)),)
    @test refdims(a) == (Y(-38.0; grid=RegularGrid(;span=2.0)),)
    @test bounds(a) == ((143.0, 147.0),)
    @test bounds(a, X) == (143.0, 147.0)

    a = da[X(1), Y(1:2)]
    @test a == [1, 2]
    @test typeof(a) <: DimensionalArray{Int,1}
    @test typeof(parent(a)) <: Array{Int,1}
    @test dims(a) == (Y(LinRange(-38, -36, 2); grid=RegularGrid(;span=2.0)),)
    @test refdims(a) == (X(143.0; grid=RegularGrid(;span=2.0)),)
    @test bounds(a) == ((-38, -34),)
    @test bounds(a, Y()) == (-38, -34)

    a = da[X(:), Y(:)]
    @test a == [1 2; 3 4]
    @test typeof(a) <: DimensionalArray{Int,2}
    @test typeof(parent(a)) <: Array{Int,2}
    @test typeof(dims(a)) <: Tuple{<:X,<:Y}
    @test dims(a) == (X(LinRange(143, 145, 2); grid=RegularGrid(;span=2.0)), 
                      Y(LinRange(-38, -36, 2); grid=RegularGrid(;span=2.0)))
    @test refdims(a) == ()
    @test bounds(a) == ((143, 147), (-38, -34))
    @test bounds(a, X) == (143, 147)
end

@testset "view returns DimensionArray containing views" begin
    v = view(da, Y(1), X(1))
    @test v[] == 1
    @test typeof(v) <: DimensionalArray{Int,0}
    @test typeof(parent(v)) <:SubArray{Int,0}
    @test typeof(dims(v)) == Tuple{}
    @test dims(v) == ()
    @test refdims(v) == (X(143.0; grid=RegularGrid(;span=2.0)), 
                         Y(-38.0; grid=RegularGrid(;span=2.0)))
    @test bounds(v) == ()

    v = view(da, Y(1), X(1:2))
    @test v == [1, 3]
    @test typeof(v) <: DimensionalArray{Int,1}
    @test typeof(parent(v)) <: SubArray{Int,1}
    @test typeof(dims(v)) <: Tuple{<:X}
    @test dims(v) == (X(LinRange(143, 145, 2); grid=RegularGrid(;span=2.0)),)
    @test refdims(v) == (Y(-38.0; grid=RegularGrid(;span=2.0)),)
    @test bounds(v) == ((143.0, 147.0),)

    v = view(da, Y(1:2), X(1:1))
    @test v == [1 2]
    @test typeof(v) <: DimensionalArray{Int,2}
    @test typeof(parent(v)) <: SubArray{Int,2}
    @test typeof(dims(v)) <: Tuple{<:X,<:Y}
    @test dims(v) == (X(LinRange(143.0, 143.0, 1); grid=RegularGrid(;span=2.0)), 
                      Y(LinRange(-38, -36, 2); grid=RegularGrid(;span=2.0)))
    @test bounds(v) == ((143.0, 145.0), (-38.0, -34.0))

    v = view(da, Y(Base.OneTo(2)), X(1))
    @test v == [1, 2]
    @test typeof(parent(v)) <: SubArray{Int,1}
    @test typeof(dims(v)) <: Tuple{<:Y}
    @test dims(v) == (Y(LinRange(-38, -36, 2); grid=RegularGrid(;span=2.0)),)
    @test refdims(v) == (X(143.0; grid=RegularGrid(;span=2.0)),)
    @test bounds(v) == ((-38.0, -34.0),)
end

a = [1 2 3 4 
     3 4 5 6 
     4 5 6 7]
dimz = (Dim{:row}((10, 30)), Dim{:column}((-20, 10)))
da = DimensionalArray(a, dimz)

@testset "arbitrary dimension names also work for indexing" begin
    @test da[Dim{:row}(2)] == [3, 4, 5, 6]
    @test da[Dim{:column}(4)] == [4, 6, 7]
    @test da[Dim{:column}(1), Dim{:row}(3)] == 4
end

@testset "size and axes" begin
    @test size(da, Dim{:row}) == 3  
    @test size(da, Dim{:column}()) == 4  
    @test axes(da, Dim{:row}()) == 1:3  
    @test axes(da, Dim{:column}) == 1:4  
end

@testset "copy" begin
    da2 = copy(da)
    @test da2 == da
    b = [4 4 4 4 
         4 4 4 4 
         4 4 4 4]
    db = DimensionalArray(deepcopy(b), dimz)
    @test db != da
    copy!(b, da)
    @test b == da
    copy!(db, da)
    @test db == da
end

@testset "broadcast" begin
    da = DimensionalArray(ones(Int, 5, 2, 4), (Y(10:20), Time(10:11), X(1:4)))
    da2 = da .* 2.0
    @test da2 == fill(2.0, 5, 2, 4)
    @test eltype(da2) <: Float64
    @test dims(da2) == (Y(LinRange(10, 20, 5); grid=RegularGrid(;span=2.5)), 
                        Time(LinRange(10.0, 11.0, 2); grid=RegularGrid(;span=1.0)), 
                        X(LinRange(1.0, 4.0, 4); grid=RegularGrid(;span=1.0)))
    da2 = da .+ fill(10, 5, 2, 4)
    @test da2 == fill(11, 5, 2, 4)
    @test eltype(da2) <: Int
end
