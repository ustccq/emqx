%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authn_password_hashing_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(SIMPLE_HASHES, [plain, md5, sha, sha256, sha512]).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(bcrypt),
    Config.

end_per_suite(_Config) ->
    ok.

t_gen_salt(_Config) ->
    Algorithms =
        [#{name => Type, salt_position => suffix} || Type <- ?SIMPLE_HASHES] ++
            [#{name => bcrypt, salt_rounds => 10}],

    lists:foreach(
        fun(Algorithm) ->
            Salt = emqx_authn_password_hashing:gen_salt(Algorithm),
            ct:pal("gen_salt(~p): ~p", [Algorithm, Salt]),
            ?assert(is_binary(Salt))
        end,
        Algorithms
    ).

t_init(_Config) ->
    Algorithms =
        [#{name => Type, salt_position => suffix} || Type <- ?SIMPLE_HASHES] ++
            [#{name => bcrypt, salt_rounds => 10}],

    lists:foreach(
        fun(Algorithm) ->
            ok = emqx_authn_password_hashing:init(Algorithm)
        end,
        Algorithms
    ).

t_check_password(_Config) ->
    lists:foreach(
        fun test_check_password/1,
        hash_examples()
    ).

test_check_password(
    #{
        password_hash := Hash,
        salt := Salt,
        password := Password,
        password_hash_algorithm := Algorithm
    } = Sample
) ->
    ct:pal("t_check_password sample: ~p", [Sample]),
    true = emqx_authn_password_hashing:check_password(Algorithm, Salt, Hash, Password),
    false = emqx_authn_password_hashing:check_password(Algorithm, Salt, Hash, <<"wrongpass">>).

t_hash(_Config) ->
    lists:foreach(
        fun test_hash/1,
        hash_examples()
    ).

test_hash(
    #{
        password := Password,
        password_hash_algorithm := Algorithm
    } = Sample
) ->
    ct:pal("t_hash sample: ~p", [Sample]),
    {Hash, Salt} = emqx_authn_password_hashing:hash(Algorithm, Password),
    true = emqx_authn_password_hashing:check_password(Algorithm, Salt, Hash, Password).

hash_examples() ->
    [
        #{
            password_hash => <<"plainsalt">>,
            salt => <<"salt">>,
            password => <<"plain">>,
            password_hash_algorithm => #{
                name => plain,
                salt_position => suffix
            }
        },
        #{
            password_hash => <<"1bc29b36f623ba82aaf6724fd3b16718">>,
            salt => <<"salt">>,
            password => <<"md5">>,
            password_hash_algorithm => #{
                name => md5,
                salt_position => disable
            }
        },
        #{
            password_hash => <<"c665d4c0a9e5498806b7d9fd0b417d272853660e">>,
            salt => <<"salt">>,
            password => <<"sha">>,
            password_hash_algorithm => #{
                name => sha,
                salt_position => prefix
            }
        },
        #{
            password_hash => <<"ac63a624e7074776d677dd61a003b8c803eb11db004d0ec6ae032a5d7c9c5caf">>,
            salt => <<"salt">>,
            password => <<"sha256">>,
            password_hash_algorithm => #{
                name => sha256,
                salt_position => prefix
            }
        },
        #{
            password_hash => <<
                "a1509ab67bfacbad020927b5ac9d91e9100a82e33a0ebb01459367ce921c0aa8"
                "157aa5652f94bc84fa3babc08283e44887d61c48bcf8ad7bcb3259ee7d0eafcd"
            >>,
            salt => <<"salt">>,
            password => <<"sha512">>,
            password_hash_algorithm => #{
                name => sha512,
                salt_position => prefix
            }
        },
        #{
            password_hash => <<"$2b$12$wtY3h20mUjjmeaClpqZVveDWGlHzCGsvuThMlneGHA7wVeFYyns2u">>,
            salt => <<"$2b$12$wtY3h20mUjjmeaClpqZVve">>,
            password => <<"bcrypt">>,

            password_hash_algorithm => #{
                name => bcrypt,
                salt_rounds => 10
            }
        },

        #{
            password_hash => <<
                "01dbee7f4a9e243e988b62c73cda935d"
                "a05378b93244ec8f48a99e61ad799d86"
            >>,
            salt => <<"ATHENA.MIT.EDUraeburn">>,
            password => <<"password">>,

            password_hash_algorithm => #{
                name => pbkdf2,
                iterations => 2,
                dk_length => 32,
                mac_fun => sha
            }
        },
        #{
            password_hash => <<"01dbee7f4a9e243e988b62c73cda935da05378b9">>,
            salt => <<"ATHENA.MIT.EDUraeburn">>,
            password => <<"password">>,

            password_hash_algorithm => #{
                name => pbkdf2,
                iterations => 2,
                mac_fun => sha
            }
        }
    ].

t_pbkdf2_schema(_Config) ->
    Config = fun(Iterations) ->
        #{
            <<"pbkdf2">> => #{
                <<"name">> => <<"pbkdf2">>,
                <<"mac_fun">> => <<"sha">>,
                <<"iterations">> => Iterations
            }
        }
    end,

    ?assertException(
        throw,
        {emqx_authn_password_hashing, _},
        hocon_tconf:check_plain(emqx_authn_password_hashing, Config(0), #{}, [pbkdf2])
    ),
    ?assertException(
        throw,
        {emqx_authn_password_hashing, _},
        hocon_tconf:check_plain(emqx_authn_password_hashing, Config(-1), #{}, [pbkdf2])
    ),
    ?assertMatch(
        #{<<"pbkdf2">> := _},
        hocon_tconf:check_plain(emqx_authn_password_hashing, Config(1), #{}, [pbkdf2])
    ).
