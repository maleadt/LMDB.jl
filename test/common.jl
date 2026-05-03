import LMDB.MDBValue
import LMDB.MDBValueIO
using LMDB
using Test

    @test LMDB.version()[1] >= v"0.9.15"

    # LMDBError
    ex = LMDBError(Cint(0))
    @test_throws LMDBError throw(ex)
    @test ex.code == 0

    # `MDBValueIO` is the package's typed-read extension point. Each
    # block below packs a Julia value into an `MDB_val` via `MDBValue`,
    # then round-trips it through `read(MDBValueIO(...), T)` to verify
    # that the default decoders match the encoded byte image.

    # String → unsafe_string over the full buffer.
    val = "abcd"
    mdb_val_ref = Ref(MDBValue(val))
    @test val == read(MDBValueIO(mdb_val_ref[]), String)

    # Vector{Int} → reinterpret + copy, owns its memory.
    val = [1233]
    T = eltype(val)
    val_size = sizeof(val)
    mdb_val_ref = Ref(MDBValue(val))
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == read(MDBValueIO(mdb_val_ref[]), Vector{Int})

    # Vector{UInt16} → same, with non-Int element type.
    val = [0x0003, 0xff45]
    val_size = sizeof(val)
    T = eltype(val)
    mdb_val_ref = Ref(MDBValue(val))
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == read(MDBValueIO(mdb_val_ref[]), Vector{UInt16})

    # Bitstype scalar inside a one-element vector → single-element
    # decode via the `Vector{T}` overload, plus a primitive scalar
    # decode (Base.read fall-through, Ref-allocating).
    struct TestType
        i::Int
        j::Char
    end
    val = TestType(1,'a')
    val_size = sizeof(val)
    T = typeof(val)
    @test_throws MethodError MDBValue(val)
    val = [val]
    mdb_val_ref = Ref(MDBValue(val))
    mdb_val = mdb_val_ref[]
    @test val_size == mdb_val.mv_size
    nvals = floor(Int, mdb_val.mv_size/sizeof(T))
    value = unsafe_wrap(Array, convert(Ptr{T}, mdb_val.mv_data), nvals)
    @test val == value
    @test val == read(MDBValueIO(mdb_val_ref[]), Vector{T})

    # Position / seek / skip primitives.
    bytes = collect(0x01:0x08)
    mdb_val_ref = Ref(MDBValue(bytes))
    io = MDBValueIO(mdb_val_ref[])
    @test position(io) == 0
    @test bytesavailable(io) == 8
    @test !eof(io)
    @test read(io, UInt8) == 0x01
    @test position(io) == 1
    skip(io, 2)
    @test read(io, UInt8) == 0x04
    seek(io, 0)
    @test read(io, UInt8) == 0x01
    seekend(io)
    @test eof(io)
    @test_throws EOFError read(io, UInt8)
