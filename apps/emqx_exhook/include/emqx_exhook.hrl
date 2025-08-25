%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(EMQX_EXHOOK_HRL).
-define(EMQX_EXHOOK_HRL, true).

-define(APP, emqx_exhook).
-define(HOOKS_REF_COUNTER, emqx_exhook_ref_counter).
-define(HOOKS_METRICS, emqx_exhook_metrics).

-define(ENABLED_HOOKS, [
    {'client.connect', {emqx_exhook_handler, on_client_connect, []}},
    {'client.connack', {emqx_exhook_handler, on_client_connack, []}},
    {'client.connected', {emqx_exhook_handler, on_client_connected, []}},
    {'client.disconnected', {emqx_exhook_handler, on_client_disconnected, []}},
    {'client.authenticate', {emqx_exhook_handler, on_client_authenticate, []}},
    {'client.authorize', {emqx_exhook_handler, on_client_authorize, []}},
    {'client.subscribe', {emqx_exhook_handler, on_client_subscribe, []}},
    {'client.unsubscribe', {emqx_exhook_handler, on_client_unsubscribe, []}},
    {'session.created', {emqx_exhook_handler, on_session_created, []}},
    {'session.subscribed', {emqx_exhook_handler, on_session_subscribed, []}},
    {'session.unsubscribed', {emqx_exhook_handler, on_session_unsubscribed, []}},
    {'session.resumed', {emqx_exhook_handler, on_session_resumed, []}},
    {'session.discarded', {emqx_exhook_handler, on_session_discarded, []}},
    {'session.takenover', {emqx_exhook_handler, on_session_takenover, []}},
    {'session.terminated', {emqx_exhook_handler, on_session_terminated, []}},
    {'message.publish', {emqx_exhook_handler, on_message_publish, []}},
    {'message.delivered', {emqx_exhook_handler, on_message_delivered, []}},
    {'message.acked', {emqx_exhook_handler, on_message_acked, []}},
    {'message.dropped', {emqx_exhook_handler, on_message_dropped, []}}
]).

-define(SERVER_FORCE_SHUTDOWN_TIMEOUT, 5000).

-endif.

-define(CMD_MOVE_FRONT, front).
-define(CMD_MOVE_REAR, rear).
-define(CMD_MOVE_BEFORE(Before), {before, Before}).
-define(CMD_MOVE_AFTER(After), {'after', After}).
