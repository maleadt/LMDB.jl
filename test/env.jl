module LMDB_Env
    using LMDB
    using Test

    const dbname = "testdb"

    # Open environemnt
    env = create()
    @test env.handle != C_NULL
    @test env[:Readers] == 126
    @test env[:KeySize] == 511
    @test env[:Flags] == 0

    # Manipulate flags
    @test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    set!(env, LMDB.MDB_NOSYNC)
    @test isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    unset!(env, LMDB.MDB_NOSYNC)
    @test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))

    # Parameters
    @test (env[:Readers] = 100) == 100
    @test (env[:MapSize] = 1000^2) == 1000^2
    @test (env[:DBs] = 10) == 10
    @test env[:Readers] == 100

    # MapSize must accept values that don't fit in Cuint (#38, PR #37, #40).
    big = Csize_t(8) * 1024^3  # 8 GiB
    @test (env[:MapSize] = big) == big

    # Setting :Flags via setindex! used to fall through to a warning (#24).
    @test !isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    env[:Flags] = LMDB.MDB_NOSYNC
    @test isflagset(env[:Flags], Cuint(LMDB.MDB_NOSYNC))
    unset!(env, LMDB.MDB_NOSYNC)

    # open db
    isdir(dbname) || mkdir(dbname)
    try
        ret = open(env, dbname)
        @test ret[1] == 0

        # Close environment
        close(env)
        @test !isopen(env)

        # do block
        create() do env
            set!(env, LMDB.MDB_NOSYNC)
            open(env, dbname)
            @test isopen(env)
        end
    finally
        rm(dbname, recursive=true)
    end
end
