%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_ai_completion_api).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").

%% Swagger specs from hocon schema
-export([
    api_spec/0,
    paths/0,
    schema/1,
    namespace/0
]).

%% API callbacks
-export([
    '/ai/models'/2,
    '/ai/providers'/2,
    '/ai/providers/:name'/2,
    '/ai/providers/:name/models'/2,
    '/ai/completion_profiles'/2,
    '/ai/completion_profiles/:name'/2
]).

-define(TAGS, [<<"AI Completion">>]).

namespace() -> "ai_completion".

%%--------------------------------------------------------------------
%% Minirest
%%--------------------------------------------------------------------

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/ai/models",
        "/ai/providers",
        "/ai/providers/:name",
        "/ai/providers/:name/models",
        "/ai/completion_profiles",
        "/ai/completion_profiles/:name"
    ].

schema("/ai/models") ->
    #{
        'operationId' => '/ai/models',
        post => #{
            tags => ?TAGS,
            summary => <<"List all AI models for a provider type">>,
            description => ?DESC(ai_model_list),
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                emqx_ai_completion_schema:provider_sctype_api(put),
                post_provider_example()
            ),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    hoconsc:array(binary()),
                    [get_models_example()]
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Provider not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_CREDENTIAL'], <<"Invalid provider">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    };
schema("/ai/providers") ->
    #{
        'operationId' => '/ai/providers',
        get => #{
            tags => ?TAGS,
            summary => <<"List all AI providers">>,
            description => ?DESC(ai_providers_list),
            parameters => [],
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    hoconsc:array(emqx_ai_completion_schema:provider_sctype_api(get)),
                    [get_provider_example()]
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        },
        post => #{
            tags => ?TAGS,
            summary => <<"Create AI provider">>,
            description => ?DESC(ai_providers_create),
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                emqx_ai_completion_schema:provider_sctype_api(post),
                post_provider_example()
            ),
            responses => #{
                204 => <<"Operation success">>,
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_CREDENTIAL'], <<"Invalid provider">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    };
schema("/ai/providers/:name") ->
    #{
        'operationId' => '/ai/providers/:name',
        get => #{
            tags => ?TAGS,
            summary => <<"Get AI provider">>,
            description => ?DESC(ai_providers_get),
            parameters => [name_param()],
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    emqx_ai_completion_schema:provider_sctype_api(get),
                    get_provider_example()
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Provider not found">>
                )
            }
        },
        put => #{
            tags => ?TAGS,
            summary => <<"Update AI provider">>,
            description => ?DESC(ai_providers_update),
            parameters => [name_param()],
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                emqx_ai_completion_schema:provider_sctype_api(put),
                put_provider_example()
            ),
            responses => #{
                204 => <<"Operation success">>,
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Provider not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_CREDENTIAL'], <<"Invalid provider">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        },
        delete => #{
            tags => ?TAGS,
            summary => <<"Delete AI provider">>,
            description => ?DESC(ai_providers_delete),
            parameters => [name_param()],
            responses => #{
                204 => <<"Operation success">>,
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Provider not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_CREDENTIAL'], <<"Invalid provider">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    };
schema("/ai/providers/:name/models") ->
    #{
        'operationId' => '/ai/providers/:name/models',
        get => #{
            tags => ?TAGS,
            summary => <<"List all AI models available for a provider">>,
            description => ?DESC(ai_providers_model_list),
            parameters => [name_param()],
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    hoconsc:array(binary()),
                    [get_models_example()]
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Provider not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_CREDENTIAL'], <<"Invalid provider">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    };
schema("/ai/completion_profiles") ->
    #{
        'operationId' => '/ai/completion_profiles',
        get => #{
            tags => ?TAGS,
            summary => <<"List all AI completion profiles">>,
            description => ?DESC(ai_completion_profiles_list),
            parameters => [],
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    hoconsc:array(emqx_ai_completion_schema:completion_profile_sctype_api(get)),
                    [get_completion_profile_example()]
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        },
        post => #{
            tags => ?TAGS,
            summary => <<"Create AI completion profile">>,
            description => ?DESC(ai_completion_profiles_create),
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                emqx_ai_completion_schema:completion_profile_sctype_api(post),
                post_completion_profile_example()
            ),
            responses => #{
                204 => <<"Operation success">>,
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_COMPLETION_PROFILE'], <<"Invalid completion profile">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    };
schema("/ai/completion_profiles/:name") ->
    #{
        'operationId' => '/ai/completion_profiles/:name',
        get => #{
            tags => ?TAGS,
            summary => <<"Get AI completion profile">>,
            description => ?DESC(ai_completion_profiles_get),
            parameters => [name_param()],
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_example(
                    emqx_ai_completion_schema:completion_profile_sctype_api(get),
                    get_completion_profile_example()
                ),
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Completion profile not found">>
                )
            }
        },
        put => #{
            tags => ?TAGS,
            summary => <<"Update AI completion profile">>,
            description => ?DESC(ai_completion_profiles_update),
            parameters => [name_param()],
            'requestBody' => emqx_dashboard_swagger:schema_with_example(
                emqx_ai_completion_schema:completion_profile_sctype_api(put),
                put_completion_profile_example()
            ),
            responses => #{
                204 => <<"Operation success">>,
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Completion profile not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_COMPLETION_PROFILE'], <<"Invalid completion profile">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        },
        delete => #{
            tags => ?TAGS,
            summary => <<"Delete AI completion profile">>,
            description => ?DESC(ai_completion_profiles_delete),
            parameters => [name_param()],
            responses => #{
                204 => <<"Operation success">>,
                404 => emqx_dashboard_swagger:error_codes(
                    ['NOT_FOUND'], <<"Completion profile not found">>
                ),
                400 => emqx_dashboard_swagger:error_codes(
                    ['INVALID_COMPLETION_PROFILE'], <<"Invalid request">>
                ),
                503 => emqx_dashboard_swagger:error_codes(
                    ['SERVICE_UNAVAILABLE'], <<"Service unavailable">>
                )
            }
        }
    }.

%%--------------------------------------------------------------------
%% Schema
%%--------------------------------------------------------------------

name_param() ->
    {name,
        hoconsc:mk(binary(), #{
            default => <<>>,
            required => true,
            desc => ?DESC(name),
            validator => fun emqx_schema:non_empty_string/1,
            in => path
        })}.

put_provider_example() ->
    #{
        <<"type">> => <<"openai">>,
        <<"api_key">> => <<"sk-1234567890">>
    }.

get_provider_example() ->
    maps:merge(
        put_provider_example(),
        #{
            <<"name">> => <<"my_provider">>,
            <<"api_key">> => <<"******">>
        }
    ).

post_provider_example() ->
    get_provider_example().

put_completion_profile_example() ->
    #{
        <<"type">> => <<"openai">>,
        <<"provider_name">> => <<"my_provider">>,
        <<"system_prompt">> => <<"You are a helpful assistant.">>,
        <<"model">> => <<"gpt-4o">>
    }.

get_completion_profile_example() ->
    maps:merge(
        #{<<"name">> => <<"my_completion_profile">>},
        put_completion_profile_example()
    ).

post_completion_profile_example() ->
    get_completion_profile_example().

get_models_example() ->
    [<<"gpt-4-0613">>, <<"gpt-4">>, <<"gpt-3.5-turbo">>].

%%--------------------------------------------------------------------
%% Minirest handlers
%%--------------------------------------------------------------------

'/ai/models'(post, #{body := CompletionProfileRaw}) ->
    case emqx_ai_completion_schema:check_provider(CompletionProfileRaw) of
        {ok, Provider} ->
            case emqx_ai_completion:list_models(Provider#{name => <<"test-provider">>}) of
                {ok, Models} ->
                    {200, Models};
                {error, Reason} ->
                    {503, #{
                        code => 'SERVICE_UNAVAILABLE',
                        message => emqx_utils:readable_error_msg(Reason)
                    }}
            end;
        {error, Reason} ->
            {400, #{
                code => 'INVALID_PROVIDER', message => emqx_utils:readable_error_msg(Reason)
            }}
    end.

'/ai/providers'(get, _Params) ->
    {200, get_providers_for_output()};
'/ai/providers'(post, #{body := NewProvider}) ->
    add_provider(NewProvider).

'/ai/providers/:name'(get, #{bindings := #{name := Name}}) ->
    case get_provider_for_output(Name) of
        not_found ->
            {404, #{code => 'NOT_FOUND', message => <<"Provider not found">>}};
        Provider ->
            {200, Provider}
    end;
'/ai/providers/:name'(put, #{body := UpdatedProvider, bindings := #{name := Name}}) ->
    update_provider(Name, UpdatedProvider#{<<"name">> => Name});
'/ai/providers/:name'(delete, #{bindings := #{name := Name}}) ->
    delete_provider(Name).

'/ai/providers/:name/models'(get, #{bindings := #{name := Name}}) ->
    case emqx_ai_completion:list_models(Name) of
        {error, provider_not_found} ->
            {404, #{code => 'NOT_FOUND', message => <<"Provider not found">>}};
        {ok, Models} ->
            {200, Models};
        {error, Reason} ->
            {503, #{
                code => 'SERVICE_UNAVAILABLE', message => emqx_utils:readable_error_msg(Reason)
            }}
    end.

'/ai/completion_profiles'(get, _Params) ->
    {200, get_completion_profiles_for_output()};
'/ai/completion_profiles'(post, #{body := NewCompletionProfile}) ->
    add_completion_profile(NewCompletionProfile).

'/ai/completion_profiles/:name'(get, #{bindings := #{name := Name}}) ->
    case get_completion_profile_for_output(Name) of
        not_found ->
            {404, #{code => 'NOT_FOUND', message => <<"Completion profile not found">>}};
        CompletionProfile ->
            {200, CompletionProfile}
    end;
'/ai/completion_profiles/:name'(put, #{
    body := UpdatedCompletionProfile, bindings := #{name := Name}
}) ->
    update_completion_profile(UpdatedCompletionProfile#{<<"name">> => Name});
'/ai/completion_profiles/:name'(delete, #{bindings := #{name := Name}}) ->
    delete_completion_profile(Name).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

get_providers_for_output() ->
    lists:map(
        fun format_provider_for_output/1,
        emqx_ai_completion_config:get_providers_raw()
    ).

get_provider_for_output(Name) ->
    case get_provider_raw(Name) of
        not_found ->
            not_found;
        ProviderRaw ->
            format_provider_for_output(ProviderRaw)
    end.

format_provider_for_output(ProviderRaw) ->
    emqx_schema:fill_defaults_for_type(
        emqx_ai_completion_schema:provider_sctype_api(get),
        ProviderRaw
    ),
    emqx_utils:redact(ProviderRaw).

get_provider_raw(Name) ->
    ProvidersRaw = [
        ProviderRaw
     || #{<<"name">> := N} = ProviderRaw <- emqx_ai_completion_config:get_providers_raw(),
        N =:= Name
    ],
    case ProvidersRaw of
        [ProviderRaw] ->
            ProviderRaw;
        _ ->
            not_found
    end.

get_completion_profile_for_output(Name) ->
    case get_completion_profile_raw(Name) of
        not_found ->
            not_found;
        CompletionProfileRaw ->
            format_completion_profile_for_output(CompletionProfileRaw)
    end.

get_completion_profile_raw(Name) ->
    CompletionProfilesRaw = [
        CompletionProfileRaw
     || #{<<"name">> := N} = CompletionProfileRaw <- emqx_ai_completion_config:get_completion_profiles_raw(),
        N =:= Name
    ],
    case CompletionProfilesRaw of
        [CompletionProfileRaw] ->
            CompletionProfileRaw;
        _ ->
            not_found
    end.

get_completion_profiles_for_output() ->
    lists:map(
        fun format_completion_profile_for_output/1,
        emqx_ai_completion_config:get_completion_profiles_raw()
    ).

format_completion_profile_for_output(CompletionProfileRaw) ->
    emqx_schema:fill_defaults_for_type(
        emqx_ai_completion_schema:completion_profile_sctype_api(get),
        CompletionProfileRaw
    ).

update_provider(Name, NewProvider0) ->
    wrap_update_error(
        case get_provider_raw(Name) of
            OldProvider when is_map(OldProvider) ->
                NewProvider = emqx_utils:deobfuscate(NewProvider0, OldProvider),
                emqx_ai_completion_config:update_providers_raw({update, NewProvider});
            not_found ->
                {error, #{reason => provider_not_found}}
        end
    ).

add_provider(NewProvider) ->
    wrap_update_error(emqx_ai_completion_config:update_providers_raw({add, NewProvider})).

delete_provider(Name) ->
    wrap_delete_error(emqx_ai_completion_config:update_providers_raw({delete, Name})).

update_completion_profile(CompletionProfile) ->
    wrap_update_error(
        emqx_ai_completion_config:update_completion_profiles_raw({update, CompletionProfile})
    ).

add_completion_profile(NewCompletionProfile) ->
    wrap_update_error(
        emqx_ai_completion_config:update_completion_profiles_raw({add, NewCompletionProfile})
    ).

delete_completion_profile(Name) ->
    wrap_delete_error(emqx_ai_completion_config:update_completion_profiles_raw({delete, Name})).

wrap_update_error(ok) ->
    {204};
wrap_update_error({error, #{reason := Reason}}) ->
    {Code, Message} = error_response(Reason),
    {http_code(Code), #{
        code => Code,
        message => Message
    }};
wrap_update_error({error, Reason}) ->
    {503, #{
        code => 'SERVICE_UNAVAILABLE',
        message => emqx_utils:readable_error_msg(Reason)
    }}.

wrap_delete_error({error, #{reason := provider_not_found}}) ->
    {204};
wrap_delete_error({error, #{reason := completion_profile_not_found}}) ->
    {204};
wrap_delete_error(Result) ->
    wrap_update_error(Result).

error_response(duplicate_provider_name) ->
    {'INVALID_CREDENTIAL', <<"Duplicate provider name">>};
error_response(provider_in_use) ->
    {'INVALID_CREDENTIAL', <<"Provider in use">>};
error_response(completion_profile_provider_type_mismatch) ->
    {'INVALID_COMPLETION_PROFILE', <<"Completion profile type does not match provider type">>};
error_response(provider_not_found) ->
    {'NOT_FOUND', <<"Provider not found">>};
error_response(duplicate_completion_profile_name) ->
    {'INVALID_COMPLETION_PROFILE', <<"Duplicate completion profile name">>};
error_response(completion_profile_provider_not_found) ->
    {'INVALID_COMPLETION_PROFILE', <<"Completion profile provider not found">>};
error_response(completion_profile_not_found) ->
    {'NOT_FOUND', <<"Completion profile not found">>};
error_response(UnknownError) ->
    {'SERVICE_UNAVAILABLE', emqx_utils:readable_error_msg(UnknownError)}.

http_code('INVALID_CREDENTIAL') ->
    400;
http_code('INVALID_COMPLETION_PROFILE') ->
    400;
http_code('NOT_FOUND') ->
    404;
http_code('SERVICE_UNAVAILABLE') ->
    503.
