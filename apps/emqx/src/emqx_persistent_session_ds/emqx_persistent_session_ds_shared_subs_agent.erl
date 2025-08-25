%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_persistent_session_ds_shared_subs_agent).

-include("shared_subs_agent.hrl").
-include("emqx_session.hrl").
-include("session_internals.hrl").

-type session_id() :: emqx_persistent_session_ds:id().

-type subscription_id() :: emqx_persistent_session_ds:subscription_id().

-type subscription() :: #{
    id := subscription_id(),
    start_time := emqx_ds:time()
}.

-type state() :: term().
-type share_topic_filter() :: emqx_types:share().

-type opts() :: #{
    session_id := session_id()
}.

%% TODO
%% This records go through network, we better shrink them, e.g. use integer keys
-type stream_lease() :: #{
    type => lease,
    subscription_id := subscription_id(),
    share_topic_filter := share_topic_filter(),
    stream := emqx_ds:stream(),
    iterator := emqx_ds:iterator()
}.

-type stream_revoke() :: #{
    type => revoke,
    subscription_id := subscription_id(),
    share_topic_filter := share_topic_filter(),
    stream := emqx_ds:stream()
}.

-type stream_lease_event() :: stream_lease() | stream_revoke().
-type event() :: stream_lease_event().

-type stream_progress() :: #{
    stream := emqx_ds:stream(),
    iterator := emqx_ds:iterator(),
    use_finished := boolean()
}.

-export_type([
    t/0,
    subscription/0,
    subscription_id/0,
    session_id/0,
    stream_lease_event/0,
    event/0,
    opts/0
]).

-export([
    new/1,
    open/2,
    pre_subscribe/3,
    has_subscription/2,
    has_subscriptions/1,

    on_subscribe/4,
    on_unsubscribe/2,
    on_stream_progress/2,
    on_info/3,
    on_disconnect/2
]).

-export([
    send/3,
    send_after/4
]).

%%--------------------------------------------------------------------
%% Behaviour
%%--------------------------------------------------------------------

-callback new(opts()) -> state().
-callback open([{share_topic_filter(), subscription()}], opts()) -> state().
-callback pre_subscribe(state(), share_topic_filter(), emqx_types:subopts()) ->
    ok | {error, term()}.
-callback has_subscription(state(), subscription_id()) -> boolean().
-callback has_subscriptions(state()) -> boolean().
-callback on_subscribe(state(), subscription_id(), share_topic_filter(), emqx_types:subopts()) ->
    state().
-callback on_unsubscribe(state(), subscription_id()) -> state().
-callback on_info(state(), subscription_id(), term()) -> {[event()], state()}.
-callback on_disconnect(state(), #{subscription_id() => [stream_progress()]}) -> state().
-callback on_stream_progress(state(), #{subscription_id() => [stream_progress()]}) -> state().

-type t() :: {module(), state()}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec new(opts()) -> t().
new(Opts) ->
    {?shared_subs_agent, ?shared_subs_agent:new(Opts)}.

-spec open([{share_topic_filter(), subscription()}], opts()) -> t().
open(Topics, Opts) ->
    {?shared_subs_agent, ?shared_subs_agent:open(Topics, Opts)}.

-spec pre_subscribe(t(), share_topic_filter(), emqx_types:subopts()) -> ok | {error, term()}.
pre_subscribe({Mod, Agent}, ShareTopicFilter, SubOpts) ->
    Mod:pre_subscribe(Agent, ShareTopicFilter, SubOpts).

-spec has_subscription(t(), subscription_id()) -> boolean().
has_subscription({Mod, Agent}, SubscriptionId) ->
    Mod:has_subscription(Agent, SubscriptionId).

-spec has_subscriptions(t()) -> boolean().
has_subscriptions({Mod, Agent}) ->
    Mod:has_subscriptions(Agent).

-spec on_subscribe(t(), subscription_id(), share_topic_filter(), emqx_types:subopts()) -> t().
on_subscribe({Mod, Agent}, SubscriptionId, ShareTopicFilter, SubOpts) ->
    {Mod, Mod:on_subscribe(Agent, SubscriptionId, ShareTopicFilter, SubOpts)}.

-spec on_unsubscribe(t(), subscription_id()) -> t().
on_unsubscribe({Mod, Agent}, SubscriptionId) ->
    {Mod, Mod:on_unsubscribe(Agent, SubscriptionId)}.

-spec on_disconnect(t(), #{subscription_id() => [stream_progress()]}) -> t().
on_disconnect({Mod, Agent}, StreamProgresses) ->
    {Mod, Mod:on_disconnect(Agent, StreamProgresses)}.

-spec on_stream_progress(t(), #{subscription_id() => [stream_progress()]}) -> t().
on_stream_progress({Mod, Agent}, StreamProgress) ->
    {Mod, Mod:on_stream_progress(Agent, StreamProgress)}.

-spec on_info(t(), subscription_id(), term()) -> {[event()], t()}.
on_info({Mod, Agent0}, SubscriptionId, Info) ->
    {Events, Agent} = Mod:on_info(Agent0, SubscriptionId, Info),
    {Events, {Mod, Agent}}.

-spec send(pid() | reference(), subscription_id(), term()) -> term().
send(Dest, SubscriptionId, Msg) ->
    erlang:send(Dest, ?session_message(?shared_sub_message(SubscriptionId, Msg))).

-spec send_after(non_neg_integer(), subscription_id(), pid() | reference(), term()) -> reference().
send_after(Time, SubscriptionId, Dest, Msg) ->
    erlang:send_after(Time, Dest, ?session_message(?shared_sub_message(SubscriptionId, Msg))).
