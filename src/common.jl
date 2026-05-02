# Build an `MDB_val` (size + raw data pointer) from a heap-rooted Julia value.
# The pointer is taken via `Base.unsafe_convert` — the same primitive ccall
# uses internally to lower `Ref{T}`/`Vector{T}`/`String` arguments. The caller
# is responsible for keeping `val` alive across the ccall (via `GC.@preserve`),
# since the resulting `MDB_val` is opaque to GC.
MDBValue() = MDB_val(zero(Csize_t), C_NULL)
MDBValue(::Nothing) = MDBValue()
MDBValue(val::String) =
    MDB_val(Csize_t(sizeof(val)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{UInt8}, val)))
MDBValue(val::AbstractArray{T}) where {T} =
    MDB_val(Csize_t(sizeof(T) * length(val)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, val)))
MDBValue(val::Base.RefValue{T}) where {T} =
    MDB_val(Csize_t(sizeof(T)),
            Ptr{Cvoid}(Base.unsafe_convert(Ptr{T}, val)))

# Self-rooted argument for `Ptr{MDB_val}` ccall sites: holds the
# `Ref{MDB_val}` box and a reference to the data buffer the box's `mv_data`
# field aliases. Returned from `cconvert` below so ccall's automatic
# `GC.@preserve` covers both the box and the data — callers never need
# explicit `Ref(...)`, `MDBValue(...)`, or `GC.@preserve` for input args.
struct MDBArg{D}
    box::Base.RefValue{MDB_val}
    data::D
end
Base.unsafe_convert(::Type{Ptr{MDB_val}}, m::MDBArg) =
    Base.unsafe_convert(Ptr{MDB_val}, m.box)

# Bare `MDB_val` (used for `delete!`'s empty val): heap-box it.
Base.cconvert(::Type{Ptr{MDB_val}}, x::MDB_val) = Ref(x)
# Pre-built `Ref{MDB_val}` (used by iterator state, and as the out-param
# for `get`/`mdb_cursor_get`): ccall reads/writes the box directly.
Base.cconvert(::Type{Ptr{MDB_val}}, x::Base.RefValue{MDB_val}) = x
# User input — heap-rooted forms with stable data pointers.
Base.cconvert(::Type{Ptr{MDB_val}}, x::String)        = MDBArg(Ref(MDBValue(x)), x)
Base.cconvert(::Type{Ptr{MDB_val}}, x::Array)         = MDBArg(Ref(MDBValue(x)), x)
Base.cconvert(::Type{Ptr{MDB_val}}, x::Base.RefValue) = MDBArg(Ref(MDBValue(x)), x)
# User input — bare bitstype scalar. Wrap in a `Ref` to give it a heap
# address, then build the `MDBArg`. The `Ref` lives in `MDBArg.data` and
# is rooted by ccall's preserve.
function Base.cconvert(::Type{Ptr{MDB_val}}, x::T) where {T}
    isbitstype(T) || throw(MethodError(Base.cconvert, (Ptr{MDB_val}, x)))
    rx = Ref(x)
    MDBArg(Ref(MDBValue(rx)), rx)
end

"""
    mdb_unpack(::Type{T}, ref::Ref{MDB_val}) -> T

Decode an `MDB_val` (size + raw `mv_data` pointer) into a Julia value of
type `T`. Called by `tryget` / `get` / cursor accessors after a
successful read. Default methods cover `String`, `Vector{E}` for any
bitstype `E`, and any bitstype scalar; all of them copy out so the
returned value is safe to keep past the producing transaction.

This is the package's customization point for typed reads — analogous
to heed's `BytesDecode<'txn>` trait. To plug in a custom value
representation (e.g. skip a framing prefix, parse a tagged buffer,
build a non-bitstype struct), define a method on a marker type:

    struct PrefixedBlob end
    function LMDB.mdb_unpack(::Type{PrefixedBlob}, ref::Ref{LMDB.MDB_val})
        v = ref[]; sz = Int(v.mv_size)
        sz < 8 && return UInt8[]
        out = Vector{UInt8}(undef, sz - 8)
        unsafe_copyto!(pointer(out),
                       Ptr{UInt8}(v.mv_data) + 8, sz - 8)
        out
    end

    LMDB.tryget(txn, dbi, key, PrefixedBlob)   # → Union{Vector{UInt8}, Nothing}

The `mv_data` pointer is into LMDB's mmap and is only valid for the
producing transaction's lifetime. Custom unpack methods must copy what
they want to keep, exactly as the default `Vector{E}` method does.
"""
mdb_unpack(::Type{T}, mdb_val_ref::Ref{MDB_val}) where {T} = _mdb_unpack(T, mdb_val_ref[])
function _mdb_unpack(::Type{T}, mdb_val::MDB_val) where {T <: String}
    unsafe_string(convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
end
function _mdb_unpack(::Type{V}, mdb_val::MDB_val) where {T, V <: Vector{T}}
    # The MDB_val data points into the LMDB-owned mmap and is only valid for
    # the lifetime of the transaction. Copy out so the returned Vector owns
    # its memory and is safe to retain past commit/abort.
    src = unsafe_wrap(Array, convert(Ptr{UInt8}, mdb_val.mv_data), mdb_val.mv_size)
    copy(reinterpret(T, src))
end
function _mdb_unpack(::Type{T}, mdb_val::MDB_val) where {T}
    unsafe_load(convert(Ptr{T}, mdb_val.mv_data))
end


"""Return the LMDB library version and version information

Function returns tuple `(VersionNumber, String)` that contains a library version and a library version string.
"""
function version()
    major = Ref{Cint}()
    minor = Ref{Cint}()
    patch = Ref{Cint}()
    ver_str = mdb_version(major, minor, patch)
    return VersionNumber(major[], minor[], patch[]), unsafe_string(ver_str)
end

""" Check if binary flag is set in provided value"""
isflagset(value, flag) = (value & flag) == flag
