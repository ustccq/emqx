%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authz_api_sources_SUITE).

-compile(nowarn_export_all).
-compile(export_all).
-compile(nowarn_update_literal).

-import(emqx_mgmt_api_test_util, [request/3, uri/1]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx_placeholder.hrl").

-define(MONGO_SINGLE_HOST, "mongo").
-define(MYSQL_HOST, "mysql:3306").
-define(PGSQL_HOST, "pgsql").
-define(REDIS_SINGLE_HOST, "redis").

-define(SOURCE_HTTP, #{
    <<"type">> => <<"http">>,
    <<"enable">> => true,
    <<"url">> => <<"https://fake.com:443/acl?username=", ?PH_USERNAME/binary>>,
    <<"ssl">> => #{<<"enable">> => true},
    <<"headers">> => #{},
    <<"method">> => <<"get">>,
    <<"request_timeout">> => <<"5s">>
}).
-define(SOURCE_MONGODB, #{
    <<"type">> => <<"mongodb">>,
    <<"enable">> => true,
    <<"mongo_type">> => <<"single">>,
    <<"server">> => <<?MONGO_SINGLE_HOST>>,
    <<"w_mode">> => <<"unsafe">>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"ssl">> => #{<<"enable">> => false},
    <<"collection">> => <<"fake">>,
    <<"filter">> => #{<<"a">> => <<"b">>}
}).
-define(SOURCE_MYSQL, #{
    <<"type">> => <<"mysql">>,
    <<"enable">> => true,
    <<"server">> => <<?MYSQL_HOST>>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"username">> => <<"xx">>,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"query">> => <<"abcb">>
}).
-define(SOURCE_POSTGRESQL, #{
    <<"type">> => <<"postgresql">>,
    <<"enable">> => true,
    <<"server">> => <<?PGSQL_HOST>>,
    <<"pool_size">> => 1,
    <<"database">> => <<"mqtt">>,
    <<"username">> => <<"xx">>,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"query">> => <<"abcb">>
}).
-define(SOURCE_REDIS, #{
    <<"type">> => <<"redis">>,
    <<"enable">> => true,
    <<"servers">> => <<?REDIS_SINGLE_HOST, ",127.0.0.1:6380">>,
    <<"redis_type">> => <<"cluster">>,
    <<"pool_size">> => 1,
    <<"password">> => <<"ee">>,
    <<"auto_reconnect">> => true,
    <<"ssl">> => #{<<"enable">> => false},
    <<"cmd">> => <<"HGETALL mqtt_authz:", ?PH_USERNAME/binary>>
}).
-define(SOURCE_FILE, #{
    <<"type">> => <<"file">>,
    <<"enable">> => true,
    <<"rules">> =>
        <<
            "{allow,{username,\"^dashboard?\"},subscribe,[\"$SYS/#\"]}."
            "\n{allow,{ipaddr,\"127.0.0.1\"},all,[\"$SYS/#\",\"#\"]}."
        >>
}).

all() ->
    emqx_common_test_helpers:all(?MODULE).

groups() ->
    [].

init_per_suite(Config) ->
    meck:new(emqx_resource, [non_strict, passthrough, no_history, no_link]),
    meck:expect(emqx_resource, create_local, fun(_, _, _, _) -> {ok, meck_data} end),
    meck:expect(emqx_resource, health_check, fun(St) -> {ok, St} end),
    meck:expect(emqx_resource, remove_local, fun(_) -> ok end),
    meck:expect(
        emqx_authz_file,
        acl_conf_file,
        fun() ->
            emqx_common_test_helpers:deps_path(emqx_auth, "etc/acl.conf")
        end
    ),

    Apps = emqx_cth_suite:start(
        [
            emqx,
            {emqx_conf,
                "authorization { cache { enable = false }, no_match = deny, sources = [] }"},
            emqx_auth,
            emqx_management,
            {emqx_dashboard, "dashboard.listeners.http { enable = true, bind = 18083 }"}
        ],
        #{
            work_dir => filename:join(?config(priv_dir, Config), ?MODULE)
        }
    ),
    ok = emqx_authz_test_lib:register_fake_sources([http, mongodb, mysql, postgresql, redis]),
    _ = emqx_common_test_http:create_default_app(),
    [{suite_apps, Apps} | Config].

end_per_suite(Config) ->
    {ok, _} = emqx:update_config(
        [authorization],
        #{
            <<"no_match">> => <<"allow">>,
            <<"cache">> => #{<<"enable">> => <<"true">>},
            <<"sources">> => []
        }
    ),
    _ = emqx_common_test_http:delete_default_app(),
    emqx_cth_suite:stop(?config(suite_apps, Config)),
    meck:unload(emqx_resource),
    ok.

init_per_testcase(t_api, Config) ->
    meck:new(emqx_utils, [non_strict, passthrough, no_history, no_link]),
    meck:expect(emqx_utils, gen_id, fun() -> "fake" end),

    meck:new(emqx, [non_strict, passthrough, no_history, no_link]),
    meck:expect(
        emqx,
        data_dir,
        fun() ->
            {data_dir, Data} = lists:keyfind(data_dir, 1, Config),
            Data
        end
    ),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(t_api, _Config) ->
    meck:unload(emqx_utils),
    meck:unload(emqx),
    ok;
end_per_testcase(_, _Config) ->
    ok.

%%------------------------------------------------------------------------------
%% Testcases
%%------------------------------------------------------------------------------

t_api(_) ->
    {ok, 200, Result1} = request(get, uri(["authorization", "sources"]), []),
    ?assertEqual([], get_sources(Result1)),

    {ok, 404, ErrResult} = request(get, uri(["authorization", "sources", "http"]), []),
    ?assertMatch(
        #{<<"code">> := <<"NOT_FOUND">>, <<"message">> := <<"Not found: http">>},
        emqx_utils_json:decode(ErrResult)
    ),

    [
        begin
            {ok, 204, _} = request(post, uri(["authorization", "sources"]), Source)
        end
     || Source <- lists:reverse([
            ?SOURCE_MONGODB, ?SOURCE_MYSQL, ?SOURCE_POSTGRESQL, ?SOURCE_REDIS, ?SOURCE_FILE
        ])
    ],
    {ok, 204, _} = request(post, uri(["authorization", "sources"]), ?SOURCE_HTTP),

    {ok, 200, Result2} = request(get, uri(["authorization", "sources"]), []),
    Sources = get_sources(Result2),
    ?assertMatch(
        [
            #{<<"type">> := <<"http">>},
            #{<<"type">> := <<"mongodb">>},
            #{<<"type">> := <<"mysql">>},
            #{<<"type">> := <<"postgresql">>},
            #{<<"type">> := <<"redis">>},
            #{<<"type">> := <<"file">>}
        ],
        Sources
    ),
    ?assert(filelib:is_file(emqx_authz_file:acl_conf_file())),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "http"]),
        ?SOURCE_HTTP#{<<"enable">> := false}
    ),
    {ok, 200, Result3} = request(get, uri(["authorization", "sources", "http"]), []),
    ?assertMatch(
        #{<<"type">> := <<"http">>, <<"enable">> := false},
        emqx_utils_json:decode(Result3)
    ),

    Keyfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "key.pem"])
    ),
    Certfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "cert.pem"])
    ),
    Cacertfile = emqx_common_test_helpers:app_path(
        emqx,
        filename:join(["etc", "certs", "cacert.pem"])
    ),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mongodb"]),
        ?SOURCE_MONGODB#{
            <<"ssl">> => #{
                <<"enable">> => <<"true">>,
                <<"cacertfile">> => Cacertfile,
                <<"certfile">> => Certfile,
                <<"keyfile">> => Keyfile,
                <<"verify">> => <<"verify_none">>
            }
        }
    ),
    {ok, 200, Result4} = request(get, uri(["authorization", "sources", "mongodb"]), []),
    {ok, 200, Status4} = request(get, uri(["authorization", "sources", "mongodb", "status"]), []),
    #{
        <<"metrics">> := #{
            <<"allow">> := 0,
            <<"deny">> := 0,
            <<"total">> := 0,
            <<"nomatch">> := 0
        }
    } = emqx_utils_json:decode(Status4),
    ?assertMatch(
        #{
            <<"type">> := <<"mongodb">>,
            <<"ssl">> := #{
                <<"enable">> := <<"true">>,
                <<"cacertfile">> := _,
                <<"certfile">> := _,
                <<"keyfile">> := _,
                <<"verify">> := <<"verify_none">>
            }
        },
        emqx_utils_json:decode(Result4)
    ),

    {ok, Cacert} = file:read_file(Cacertfile),
    {ok, Cert} = file:read_file(Certfile),
    {ok, Key} = file:read_file(Keyfile),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mongodb"]),
        ?SOURCE_MONGODB#{
            <<"ssl">> => #{
                <<"enable">> => <<"true">>,
                <<"cacertfile">> => Cacert,
                <<"certfile">> => Cert,
                <<"keyfile">> => Key,
                <<"verify">> => <<"verify_none">>
            }
        }
    ),
    {ok, 200, Result5} = request(get, uri(["authorization", "sources", "mongodb"]), []),
    ?assertMatch(
        #{
            <<"type">> := <<"mongodb">>,
            <<"ssl">> := #{
                <<"enable">> := <<"true">>,
                <<"cacertfile">> := _,
                <<"certfile">> := _,
                <<"keyfile">> := _,
                <<"verify">> := <<"verify_none">>
            }
        },
        emqx_utils_json:decode(Result5)
    ),

    {ok, 200, Status5_1} = request(get, uri(["authorization", "sources", "mongodb", "status"]), []),
    #{
        <<"metrics">> := #{
            <<"allow">> := 0,
            <<"deny">> := 0,
            <<"total">> := 0,
            <<"nomatch">> := 0
        }
    } = emqx_utils_json:decode(Status5_1),

    #{
        config := #{
            ssl := #{
                cacertfile := SavedCacertfile,
                certfile := SavedCertfile,
                keyfile := SavedKeyfile
            }
        }
    } = emqx_authz:lookup_state(mongodb),

    ?assert(filelib:is_file(SavedCacertfile)),
    ?assert(filelib:is_file(SavedCertfile)),
    ?assert(filelib:is_file(SavedKeyfile)),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "mysql"]),
        ?SOURCE_MYSQL#{<<"server">> := <<"192.168.1.100:3306">>}
    ),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "postgresql"]),
        ?SOURCE_POSTGRESQL#{<<"server">> := <<"fake">>}
    ),

    {ok, 204, _} = request(
        put,
        uri(["authorization", "sources", "redis"]),
        ?SOURCE_REDIS#{
            <<"servers">> := [
                <<"192.168.1.100:6379">>,
                <<"192.168.1.100:6380">>
            ]
        }
    ),

    {ok, 400, TypeMismatch} = request(
        put,
        uri(["authorization", "sources", "file"]),
        #{<<"type">> => <<"built_in_database">>, <<"enable">> => false}
    ),
    ?assertMatch(
        #{
            <<"code">> := <<"BAD_REQUEST">>,
            <<"message">> := <<"Type mismatch", _/binary>>
        },
        emqx_utils_json:decode(TypeMismatch)
    ),

    lists:foreach(
        fun(#{<<"type">> := Type}) ->
            {ok, 204, _} = request(
                delete,
                uri(["authorization", "sources", binary_to_list(Type)]),
                []
            )
        end,
        Sources
    ),
    {ok, 200, Result6} = request(get, uri(["authorization", "sources"]), []),
    ?assertEqual([], get_sources(Result6)),
    ?assertEqual([], emqx:get_config([authorization, sources])),

    lists:foreach(
        fun(#{<<"type">> := Type}) ->
            {ok, 404, _} = request(
                get,
                uri(["authorization", "sources", binary_to_list(Type), "status"]),
                []
            ),
            {ok, 404, _} = request(
                post,
                uri(["authorization", "sources", binary_to_list(Type), "move"]),
                #{<<"position">> => <<"front">>}
            ),
            {ok, 404, _} = request(
                get,
                uri(["authorization", "sources", binary_to_list(Type)]),
                []
            ),
            {ok, 404, _} = request(
                delete,
                uri(["authorization", "sources", binary_to_list(Type)]),
                []
            )
        end,
        Sources
    ),

    {ok, 404, _TypeMismatch2} = request(
        put,
        uri(["authorization", "sources", "file"]),
        #{<<"type">> => <<"built_in_database">>, <<"enable">> => false}
    ),
    {ok, 404, _} = request(
        put,
        uri(["authorization", "sources", "built_in_database"]),
        #{<<"type">> => <<"built_in_database">>, <<"enable">> => false}
    ),

    {ok, 204, _} = request(post, uri(["authorization", "sources"]), ?SOURCE_FILE),

    {ok, Client} = emqtt:start_link(
        [
            {username, <<"u_event3">>},
            {clientid, <<"c_event3">>},
            {proto_ver, v5},
            {properties, #{'Session-Expiry-Interval' => 60}}
        ]
    ),
    emqtt:connect(Client),

    emqtt:publish(
        Client,
        <<"t1">>,
        #{'Message-Expiry-Interval' => 60},
        <<"{\"id\": 1, \"name\": \"ha\"}">>,
        [{qos, 1}]
    ),

    snabbkaffe:retry(
        10,
        3,
        fun() ->
            {ok, 200, Status5} = request(
                get, uri(["authorization", "sources", "file", "status"]), []
            ),
            #{
                <<"metrics">> := #{
                    <<"allow">> := 1,
                    <<"deny">> := 0,
                    <<"total">> := 1,
                    <<"nomatch">> := 0
                }
            } = emqx_utils_json:decode(Status5)
        end
    ),

    emqtt:publish(
        Client,
        <<"t2">>,
        #{'Message-Expiry-Interval' => 60},
        <<"{\"id\": 1, \"name\": \"ha\"}">>,
        [{qos, 1}]
    ),

    snabbkaffe:retry(
        10,
        3,
        fun() ->
            {ok, 200, Status6} = request(
                get, uri(["authorization", "sources", "file", "status"]), []
            ),
            #{
                <<"metrics">> := #{
                    <<"allow">> := 2,
                    <<"deny">> := 0,
                    <<"total">> := 2,
                    <<"nomatch">> := 0
                }
            } = emqx_utils_json:decode(Status6)
        end
    ),

    emqtt:publish(
        Client,
        <<"t3">>,
        #{'Message-Expiry-Interval' => 60},
        <<"{\"id\": 1, \"name\": \"ha\"}">>,
        [{qos, 1}]
    ),

    snabbkaffe:retry(
        10,
        3,
        fun() ->
            {ok, 200, Status7} = request(
                get, uri(["authorization", "sources", "file", "status"]), []
            ),
            #{
                <<"metrics">> := #{
                    <<"allow">> := 3,
                    <<"deny">> := 0,
                    <<"total">> := 3,
                    <<"nomatch">> := 0
                }
            } = emqx_utils_json:decode(Status7)
        end
    ),
    ok.

t_source_move(_) ->
    {ok, _} = emqx_authz:update(replace, [
        ?SOURCE_HTTP, ?SOURCE_MONGODB, ?SOURCE_MYSQL, ?SOURCE_POSTGRESQL, ?SOURCE_REDIS
    ]),
    ?assertMatch(
        [
            #{type := http},
            #{type := mongodb},
            #{type := mysql},
            #{type := postgresql},
            #{type := redis}
        ],
        emqx_authz:lookup_states()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "postgresql", "move"]),
        #{<<"position">> => <<"front">>}
    ),
    ?assertMatch(
        [
            #{type := postgresql},
            #{type := http},
            #{type := mongodb},
            #{type := mysql},
            #{type := redis}
        ],
        emqx_authz:lookup_states()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "http", "move"]),
        #{<<"position">> => <<"rear">>}
    ),
    ?assertMatch(
        [
            #{type := postgresql},
            #{type := mongodb},
            #{type := mysql},
            #{type := redis},
            #{type := http}
        ],
        emqx_authz:lookup_states()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "mysql", "move"]),
        #{<<"position">> => <<"before:postgresql">>}
    ),
    ?assertMatch(
        [
            #{type := mysql},
            #{type := postgresql},
            #{type := mongodb},
            #{type := redis},
            #{type := http}
        ],
        emqx_authz:lookup_states()
    ),

    {ok, 204, _} = request(
        post,
        uri(["authorization", "sources", "mongodb", "move"]),
        #{<<"position">> => <<"after:http">>}
    ),
    ?assertMatch(
        [
            #{type := mysql},
            #{type := postgresql},
            #{type := redis},
            #{type := http},
            #{type := mongodb}
        ],
        emqx_authz:lookup_states()
    ),

    ok.

t_sources_reorder(_) ->
    %% Disabling an auth source must not affect the requested order
    MongoDbDisabled = (?SOURCE_MONGODB)#{<<"enable">> => false},
    {ok, _} = emqx_authz:update(replace, [
        ?SOURCE_HTTP, MongoDbDisabled, ?SOURCE_MYSQL, ?SOURCE_POSTGRESQL, ?SOURCE_REDIS
    ]),
    ?assertMatch(
        [
            #{type := http},
            #{type := mongodb},
            #{type := mysql},
            #{type := postgresql},
            #{type := redis}
        ],
        emqx_authz:lookup_states()
    ),

    OrderUri = uri(["authorization", "sources", "order"]),

    %% Valid moves
    {ok, 204, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>},
            #{<<"type">> => <<"mongodb">>}
        ]
    ),
    ?assertMatch(
        [
            #{type := redis},
            #{type := http},
            #{type := postgresql},
            #{type := mysql},
            #{type := mongodb, enable := false}
        ],
        emqx_authz:lookup_states()
    ),

    %% Invalid moves

    %% Bad schema
    {ok, 400, _} = request(
        put,
        OrderUri,
        [#{<<"not-type">> => <<"redis">>}]
    ),
    {ok, 400, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"unkonw">>},
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>},
            #{<<"type">> => <<"mongodb">>}
        ]
    ),

    %% Partial order
    {ok, 400, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>}
        ]
    ),

    %% Not found authenticators
    {ok, 400, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>},
            #{<<"type">> => <<"mongodb">>},
            #{<<"type">> => <<"built_in_database">>},
            #{<<"type">> => <<"file">>}
        ]
    ),

    %% Both partial and not found errors
    {ok, 400, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>},
            #{<<"type">> => <<"built_in_database">>}
        ]
    ),

    %% Duplicates
    {ok, 400, _} = request(
        put,
        OrderUri,
        [
            #{<<"type">> => <<"redis">>},
            #{<<"type">> => <<"http">>},
            #{<<"type">> => <<"postgresql">>},
            #{<<"type">> => <<"mysql">>},
            #{<<"type">> => <<"mongodb">>},
            #{<<"type">> => <<"http">>}
        ]
    ).

t_aggregate_metrics(_) ->
    Metrics = #{
        'emqx@node1.emqx.io' => #{
            metrics =>
                #{
                    failed => 0,
                    total => 1,
                    rate => 0.0,
                    rate_last5m => 0.0,
                    rate_max => 0.1,
                    success => 1
                }
        },
        'emqx@node2.emqx.io' => #{
            metrics =>
                #{
                    failed => 0,
                    total => 1,
                    rate => 0.0,
                    rate_last5m => 0.0,
                    rate_max => 0.1,
                    success => 1
                }
        }
    },
    Res = emqx_authn_api:aggregate_metrics(maps:values(Metrics)),
    ?assertEqual(
        #{
            metrics =>
                #{
                    failed => 0,
                    total => 2,
                    rate => 0.0,
                    rate_last5m => 0.0,
                    rate_max => 0.2,
                    success => 2
                }
        },
        Res
    ).

get_sources(Result) ->
    maps:get(<<"sources">>, emqx_utils_json:decode(Result)).

data_dir() -> emqx:data_dir().
