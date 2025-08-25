%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_authz_file).

-include_lib("emqx/include/logger.hrl").

-behaviour(emqx_authz_source).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

%% APIs
-export([
    create/1,
    update/2,
    destroy/1,
    authorize/4
]).

-export([
    validate/1,
    write_files/1,
    read_files/1
]).

%% For testing
-export([
    acl_conf_file/0
]).

%%------------------------------------------------------------------------------
%% Authz Source Callbacks
%%------------------------------------------------------------------------------

create(#{path := Path} = Source) ->
    {ok, Rules} = validate(Path),
    emqx_authz_utils:init_state(Source, #{rules => Rules}).

update(_State, #{path := _Path} = Source) ->
    create(Source).

destroy(_Source) -> ok.

authorize(Client, PubSub, Topic, #{rules := Rules}) ->
    emqx_authz_rule:matches(Client, PubSub, Topic, Rules).

read_files(#{<<"path">> := Path} = Source) ->
    {ok, Rules} = read_file(Path),
    maps:remove(<<"path">>, Source#{<<"rules">> => Rules});
read_files(#{<<"rules">> := _} = Source) ->
    Source.

write_files(#{<<"rules">> := Rules} = Source0) ->
    AclPath = ?MODULE:acl_conf_file(),
    %% Always check if the rules are valid before writing to the file
    %% If the rules are invalid, the old file will be kept
    ok = check_acl_file_rules(AclPath, Rules),
    ok = write_file(AclPath, Rules),
    Source1 = maps:remove(<<"rules">>, Source0),
    maps:put(<<"path">>, AclPath, Source1);
write_files(#{<<"path">> := _} = Source) ->
    Source.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

validate(Path0) ->
    Path = filename(Path0),
    Rules =
        case file:consult(Path) of
            {ok, Terms} ->
                [emqx_authz_rule:compile(Term) || Term <- Terms];
            {error, Reason} when is_atom(Reason) ->
                ?SLOG(alert, #{
                    msg => failed_to_read_acl_file,
                    path => Path,
                    explain => emqx_utils:explain_posix(Reason)
                }),
                throw(failed_to_read_acl_file);
            {error, Reason} ->
                ?SLOG(alert, #{msg => bad_acl_file_content, path => Path, reason => Reason}),
                throw({bad_acl_file_content, Reason})
        end,
    {ok, Rules}.

read_file(Path) ->
    file:read_file(filename(Path)).

write_file(Filename, Bytes) ->
    ok = filelib:ensure_dir(Filename),
    case file:write_file(Filename, Bytes) of
        ok ->
            ok;
        {error, Reason} ->
            ?SLOG(error, #{filename => Filename, msg => "write_file_error", reason => Reason}),
            throw(Reason)
    end.

filename(PathMaybeTemplate) ->
    emqx_schema:naive_env_interpolation(PathMaybeTemplate).

%% @doc where the acl.conf file is stored.
acl_conf_file() ->
    filename:join([emqx:data_dir(), "authz", "acl.conf"]).

check_acl_file_rules(Path, Rules) ->
    TmpPath = Path ++ ".tmp",
    try
        ok = write_file(TmpPath, Rules),
        {ok, _} = validate(TmpPath),
        ok
    catch
        throw:Reason -> throw(Reason)
    after
        _ = file:delete(TmpPath)
    end.
