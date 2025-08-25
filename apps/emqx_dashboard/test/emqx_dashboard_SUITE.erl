%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_dashboard_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-import(
    emqx_common_test_http,
    [
        request_api/3,
        request_api/5,
        get_http_data/1
    ]
).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/asserts.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("emqx_dashboard.hrl").

-define(HOST, "http://127.0.0.1:18083").

-define(BASE_PATH, "/api/v5").

-define(OVERVIEWS, [
    "alarms",
    "banned",
    "stats",
    "metrics",
    "listeners",
    "clients",
    "subscriptions"
]).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    %% Load all applications to ensure swagger.json is fully generated.
    Apps = emqx_machine_boot:reboot_apps(),
    ct:pal("load apps:~p~n", [Apps]),
    lists:foreach(fun(App) -> application:load(App) end, Apps),
    SuiteApps = emqx_cth_suite:start(
        [
            emqx_conf,
            emqx_management,
            emqx_mgmt_api_test_util:emqx_dashboard()
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    _ = emqx_conf_schema:roots(),
    ok = emqx_dashboard_desc_cache:init(),
    [{suite_apps, SuiteApps} | Config].

end_per_suite(Config) ->
    emqx_cth_suite:stop(?config(suite_apps, Config)).

t_overview(_) ->
    mnesia:clear_table(?ADMIN),
    emqx_dashboard_admin:add_user(
        <<"admin">>, <<"public_www1">>, ?ROLE_SUPERUSER, <<"simple_description">>
    ),
    Headers = auth_header_(<<"admin">>, <<"public_www1">>),
    [
        {ok, _} = request_dashboard(get, api_path([Overview]), Headers)
     || Overview <- ?OVERVIEWS
    ].

t_dashboard_restart(Config) ->
    emqx_config:put([dashboard], #{
        i18n_lang => en,
        swagger_support => true,
        listeners =>
            #{
                http =>
                    #{
                        inet6 => false,
                        bind => 18083,
                        ipv6_v6only => false,
                        send_timeout => 10000,
                        num_acceptors => 8,
                        max_connections => 512,
                        backlog => 1024,
                        proxy_header => false
                    }
            }
    }),
    application:stop(emqx_dashboard),
    application:start(emqx_dashboard),
    Name = 'http:dashboard',
    t_overview(Config),
    [{'_', [], Rules}] = BaseDispatch = persistent_term:get(Name),

    %% complete dispatch has more than 150 rules.
    ?assertNotMatch([{[], [], cowboy_static, _} | _], Rules),
    ?assert(erlang:length(Rules) > 150),

    %% After we restart the dashboard, the dispatch rules should be the same.
    ok = application:stop(emqx_dashboard),
    assert_same_dispatch(BaseDispatch, Name, step_0),
    ok = application:start(emqx_dashboard),
    assert_same_dispatch(BaseDispatch, Name, step_1),
    t_overview(Config),

    %% erase to mock the initial dashboard startup.
    persistent_term:erase(Name),
    ok = application:stop(emqx_dashboard),
    ok = application:start(emqx_dashboard),
    assert_same_dispatch(BaseDispatch, Name, step_2),
    t_overview(Config),
    ok.

t_admins_add_delete(_) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"simple description">>,
    {ok, _} = emqx_dashboard_admin:add_user(
        <<"username">>, <<"password_0">>, ?ROLE_SUPERUSER, Desc
    ),
    {ok, _} = emqx_dashboard_admin:add_user(
        <<"username1">>, <<"password1">>, ?ROLE_SUPERUSER, Desc
    ),
    Admins = emqx_dashboard_admin:all_users(),
    ?assertEqual(2, length(Admins)),
    {ok, _} = emqx_dashboard_admin:remove_user(<<"username1">>),
    Users = emqx_dashboard_admin:all_users(),
    ?assertEqual(1, length(Users)),
    {ok, _} = emqx_dashboard_admin:change_password(
        <<"username">>,
        <<"password_0">>,
        <<"new_pwd_1234">>
    ),
    timer:sleep(10),
    {ok, _} = emqx_dashboard_admin:remove_user(<<"username">>).

t_admin_delete_self_failed(_) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"simple description">>,
    _ = emqx_dashboard_admin:add_user(<<"username1">>, <<"password_1">>, ?ROLE_SUPERUSER, Desc),
    Admins = emqx_dashboard_admin:all_users(),
    ?assertEqual(1, length(Admins)),
    Header = auth_header_(<<"username1">>, <<"password_1">>),
    {error, {_, 400, _}} = request_dashboard(delete, api_path(["users", "username1"]), Header),
    Token = ["Basic ", base64:encode("username1:password_1")],
    Header2 = {"Authorization", Token},
    {error, {_, 401, _}} = request_dashboard(delete, api_path(["users", "username1"]), Header2),
    mnesia:clear_table(?ADMIN).

%% This verifies that we can delete the default admin only if there is at least another
%% admin username in the database.
t_admin_delete_default_username(_TCConfig) ->
    mnesia:clear_table(?ADMIN),
    DefaultUsername = emqx_dashboard_admin:default_username(),
    DefaultPassword = emqx_dashboard_admin:default_password(),
    %% Sanity checks
    ?assertNotEqual(<<"">>, DefaultUsername),
    ?assertNotEqual(<<"">>, DefaultPassword),
    {ok, #{}} = emqx_dashboard_admin:add_default_user(),
    HeaderDefault = auth_header_(DefaultUsername, DefaultPassword),
    ?assertMatch(
        {error, {_, 400, _}},
        request_dashboard(delete, api_path(["users", DefaultUsername]), HeaderDefault)
    ),
    NewAdmin = <<"newadmin">>,
    NewPassword = <<"newadminpassword_123">>,
    {ok, #{}} = emqx_dashboard_admin:add_user(
        NewAdmin, NewPassword, ?ROLE_SUPERUSER, <<"description">>
    ),
    NewHeader = auth_header_(NewAdmin, NewPassword),
    %% Now we can delete the default admin user
    ?assertMatch(
        {ok, _},
        request_dashboard(delete, api_path(["users", DefaultUsername]), NewHeader)
    ),
    ?assertMatch(
        {error, {_, 404, _}},
        request_dashboard(delete, api_path(["users", DefaultUsername]), NewHeader)
    ),
    %% Cannot delete self
    ?assertMatch(
        {error, {_, 400, _}},
        request_dashboard(delete, api_path(["users", NewAdmin]), NewHeader)
    ),
    %% Restarting the application should not restore the default admin user
    ?assertMatch([_], emqx_dashboard_admin:admin_users()),
    ok = application:stop(emqx_dashboard),
    ok = application:start(emqx_dashboard),
    ?assertMatch([_], emqx_dashboard_admin:admin_users()),
    ok.

t_rest_api(_Config) ->
    mnesia:clear_table(?ADMIN),
    Desc = <<"administrator">>,
    Password = <<"public_www1">>,
    emqx_dashboard_admin:add_user(<<"admin">>, Password, ?ROLE_SUPERUSER, Desc),
    {ok, 200, Res0} = http_get(["users"]),
    ?assertEqual(
        [
            filter_req(#{
                <<"backend">> => <<"local">>,
                <<"username">> => <<"admin">>,
                <<"description">> => <<"administrator">>,
                <<"role">> => ?ROLE_SUPERUSER,
                <<"namespace">> => null,
                <<"mfa">> => <<"none">>
            })
        ],
        get_http_data(Res0)
    ),
    {ok, 200, _} = http_put(
        ["users", "admin"],
        filter_req(#{
            <<"role">> => ?ROLE_SUPERUSER,
            <<"description">> => <<"a_new_description">>
        })
    ),
    {ok, 200, _} = http_post(
        ["users"],
        filter_req(#{
            <<"username">> => <<"usera">>,
            <<"password">> => <<"passwd_01234">>,
            <<"role">> => ?ROLE_SUPERUSER,
            <<"mfa">> => <<"none">>,
            <<"description">> => Desc
        })
    ),
    {ok, 204, _} = http_delete(["users", "usera"]),
    {ok, 404, _} = http_delete(["users", "usera"]),
    {ok, 204, _} = http_post(
        ["users", "admin", "change_pwd"],
        #{
            <<"old_pwd">> => Password,
            <<"new_pwd">> => <<"newpwd_lkdfki1">>
        }
    ),
    mnesia:clear_table(?ADMIN),
    emqx_dashboard_admin:add_user(<<"admin">>, Password, ?ROLE_SUPERUSER, <<"administrator">>),
    ok.

t_swagger_json(_Config) ->
    Url = ?HOST ++ "/api-docs/swagger.json",
    %% with auth
    Auth = auth_header_(<<"admin">>, <<"public_www1">>),
    {ok, 200, Body1} = request_api(get, Url, Auth),
    ?assert(emqx_utils_json:is_json(Body1)),
    %% without auth
    {ok, {{"HTTP/1.1", 200, "OK"}, _Headers, Body2}} =
        httpc:request(get, {Url, []}, [], [{body_format, binary}]),
    ?assertEqual(Body1, Body2),
    ?assertMatch(
        #{
            <<"info">> := #{
                <<"title">> := _,
                <<"version">> := _
            }
        },
        emqx_utils_json:decode(Body1)
    ),
    ok.

t_disable_swagger_json(_Config) ->
    Url = ?HOST ++ "/api-docs/index.html",
    ?assertMatch(
        {ok, {{"HTTP/1.1", 200, "OK"}, __, _}},
        httpc:request(get, {Url, []}, [], [{body_format, binary}])
    ),
    DashboardCfg = emqx:get_raw_config([dashboard]),
    ?check_trace(
        {_, {ok, _}} = ?wait_async_action(
            begin
                DashboardCfg2 = DashboardCfg#{<<"swagger_support">> => false},
                emqx:update_config([dashboard], DashboardCfg2)
            end,
            #{?snk_kind := regenerate_dispatch, i18n_lang := en},
            3_000
        ),
        []
    ),
    ?assertMatch(
        {ok, {{"HTTP/1.1", 404, "Not Found"}, _, _}},
        httpc:request(get, {Url, []}, [], [{body_format, binary}])
    ),
    ?check_trace(
        {_, {ok, _}} = ?wait_async_action(
            begin
                DashboardCfg3 = DashboardCfg#{<<"swagger_support">> => true},
                emqx:update_config([dashboard], DashboardCfg3)
            end,
            #{?snk_kind := regenerate_dispatch, i18n_lang := en},
            3_000
        ),
        []
    ),
    ?assertMatch(
        {ok, {{"HTTP/1.1", 200, "OK"}, _, _}},
        httpc:request(get, {Url, []}, [], [{body_format, binary}])
    ).

t_cli(_Config) ->
    [mria:dirty_delete(?ADMIN, Admin) || Admin <- mnesia:dirty_all_keys(?ADMIN)],
    emqx_dashboard_cli:admins(["add", "username", "password_ww2"]),
    [#?ADMIN{username = <<"username">>, pwdhash = <<Salt:4/binary, Hash/binary>>}] =
        emqx_dashboard_admin:lookup_user(<<"username">>),
    ?assertEqual(Hash, crypto:hash(sha256, <<Salt/binary, <<"password_ww2">>/binary>>)),
    emqx_dashboard_cli:admins(["passwd", "username", "new_password"]),
    [#?ADMIN{username = <<"username">>, pwdhash = <<Salt1:4/binary, Hash1/binary>>}] =
        emqx_dashboard_admin:lookup_user(<<"username">>),
    ?assertEqual(Hash1, crypto:hash(sha256, <<Salt1/binary, <<"new_password">>/binary>>)),
    emqx_dashboard_cli:admins(["del", "username"]),
    [] = emqx_dashboard_admin:lookup_user(<<"username">>),
    emqx_dashboard_cli:admins(["add", "admin1", "pass_lkdfkd1"]),
    emqx_dashboard_cli:admins(["add", "admin2", "w_pass_lkdfkd2"]),
    AdminList = emqx_dashboard_admin:all_users(),
    ?assertEqual(2, length(AdminList)).

t_lookup_by_username_jwt(_Config) ->
    User = bin(["user-", integer_to_list(random_num())]),
    emqx_dashboard_token:sign(#?ADMIN{username = User}),
    ?assertMatch(
        [#?ADMIN_JWT{username = User}],
        emqx_dashboard_token:lookup_by_username(User)
    ),
    ok = emqx_dashboard_token:destroy_by_username(User),
    %% issue a gen_server call to sync the async destroy gen_server cast
    ok = gen_server:call(emqx_dashboard_token, dummy, infinity),
    ?assertMatch([], emqx_dashboard_token:lookup_by_username(User)),
    ok.

t_clean_expired_jwt(_Config) ->
    User = bin(["user-", integer_to_list(random_num())]),
    emqx_dashboard_token:sign(#?ADMIN{username = User}),
    [#?ADMIN_JWT{username = User, exptime = ExpTime}] =
        emqx_dashboard_token:lookup_by_username(User),
    ok = emqx_dashboard_token:clean_expired_jwt(_Now1 = ExpTime),
    ?assertMatch(
        [#?ADMIN_JWT{username = User}],
        emqx_dashboard_token:lookup_by_username(User)
    ),
    ok = emqx_dashboard_token:clean_expired_jwt(_Now2 = ExpTime + 1),
    ?assertMatch([], emqx_dashboard_token:lookup_by_username(User)),
    ok.

t_default_password_file(Config) ->
    Password = <<"passwordfromfile">>,
    Passfile = filename:join(?config(priv_dir, Config), "passfile"),
    FileURI = iolist_to_binary([<<"file://">>, Passfile]),
    ok = file:write_file(Passfile, Password),
    Port = 18089,
    AppSpecs = [
        emqx_conf,
        {emqx_dashboard, #{
            config =>
                #{
                    <<"dashboard">> =>
                        #{
                            <<"listeners">> => #{
                                <<"http">> => #{
                                    <<"enable">> => true,
                                    %% to avoid clash with master test node
                                    <<"bind">> => Port
                                }
                            },
                            <<"default_password">> => FileURI
                        }
                }
        }}
    ],
    Nodes = emqx_cth_cluster:start(
        [{dash_default_pass1, #{apps => AppSpecs}}],
        #{work_dir => emqx_cth_suite:work_dir(?FUNCTION_NAME, Config)}
    ),
    Username = <<"admin">>,
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ filename:join([?BASE_PATH, "login"]),
    Body = emqx_utils_json:encode(#{username => Username, password => Password}),
    ?assertMatch(
        {ok, {{_, 200, _}, _, _}},
        httpc:request(post, {URL, [], "application/json", Body}, [], [{body_format, binary}])
    ),
    emqx_cth_cluster:stop(Nodes),
    ok.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

bin(X) -> iolist_to_binary(X).

random_num() ->
    erlang:system_time(nanosecond).

http_get(Parts) ->
    request_api(get, api_path(Parts), auth_header_(<<"admin">>, <<"public_www1">>)).

http_delete(Parts) ->
    request_api(delete, api_path(Parts), auth_header_(<<"admin">>, <<"public_www1">>)).

http_post(Parts, Body) ->
    request_api(post, api_path(Parts), [], auth_header_(<<"admin">>, <<"public_www1">>), Body).

http_put(Parts, Body) ->
    request_api(put, api_path(Parts), [], auth_header_(<<"admin">>, <<"public_www1">>), Body).

request_dashboard(Method, Url, Auth) ->
    Request = {Url, [Auth]},
    do_request_dashboard(Method, Request).
request_dashboard(Method, Url, QueryParams, Auth) ->
    Request = {Url ++ "?" ++ QueryParams, [Auth]},
    do_request_dashboard(Method, Request).

do_request_dashboard(Method, {Url, _} = Request) ->
    ct:pal("Method: ~p, Request: ~p", [Method, Request]),
    case httpc:request(Method, Request, maybe_ssl(Url), []) of
        {error, socket_closed_remotely} ->
            {error, socket_closed_remotely};
        {ok, {{"HTTP/1.1", Code, _}, _Headers, Return}} when
            Code >= 200 andalso Code =< 299
        ->
            {ok, Return};
        {ok, {Reason, _, _}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

maybe_ssl("http://" ++ _) -> [];
maybe_ssl("https://" ++ _) -> [{ssl, [{verify, verify_none}]}].

auth_header_() ->
    auth_header_(<<"admin">>, <<"public">>).

auth_header_(Username, Password) ->
    {ok, #{token := Token}} = emqx_dashboard_admin:sign_token(Username, Password),
    {"Authorization", "Bearer " ++ binary_to_list(Token)}.

api_path(Parts) ->
    ?HOST ++ filename:join([?BASE_PATH | Parts]).

json(Data) ->
    emqx_utils_json:decode(Data).

assert_same_dispatch([{'_', [], BaseRoutes}], Name, Tag) ->
    [{'_', [], NewRoutes}] = persistent_term:get(Name, Tag),
    snabbkaffe_diff:assert_lists_eq(BaseRoutes, NewRoutes, #{comment => Tag}).

-if(?EMQX_RELEASE_EDITION == ee).
filter_req(Req) ->
    Req.

-else.

filter_req(Req) ->
    maps:without([role, <<"role">>, backend, <<"backend">>], Req).

-endif.
