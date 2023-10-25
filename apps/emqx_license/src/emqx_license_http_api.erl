%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_license_http_api).

-behaviour(minirest_api).

-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/logger.hrl").

-export([
    namespace/0,
    api_spec/0,
    paths/0,
    schema/1,
    fields/1
]).
-define(LICENSE_TAGS, [<<"License">>]).

-export([
    '/license'/2,
    '/license/setting'/2
]).

-define(BAD_REQUEST, 'BAD_REQUEST').

namespace() -> "license_http_api".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => false}).

paths() ->
    [
        "/license",
        "/license/setting"
    ].

schema("/license") ->
    #{
        'operationId' => '/license',
        get => #{
            tags => ?LICENSE_TAGS,
            summary => <<"Get license info">>,
            description => ?DESC("desc_license_info_api"),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_examples(
                    map(),
                    #{
                        sample_license_info => #{
                            value => sample_license_info_response()
                        }
                    }
                )
            }
        },
        %% TODO(5.x): It's a update action, should use PUT instead
        post => #{
            tags => ?LICENSE_TAGS,
            summary => <<"Update license key">>,
            description => ?DESC("desc_license_key_api"),
            'requestBody' => emqx_dashboard_swagger:schema_with_examples(
                hoconsc:ref(?MODULE, key_license),
                #{
                    license_key => #{
                        summary => <<"License key string">>,
                        value => #{
                            <<"key">> => <<"xxx">>
                        }
                    }
                }
            ),
            responses => #{
                200 => emqx_dashboard_swagger:schema_with_examples(
                    map(),
                    #{
                        sample_license_info => #{
                            value => sample_license_info_response()
                        }
                    }
                ),
                400 => emqx_dashboard_swagger:error_codes([?BAD_REQUEST], <<"Bad license key">>)
            }
        }
    };
schema("/license/setting") ->
    #{
        'operationId' => '/license/setting',
        get => #{
            tags => ?LICENSE_TAGS,
            summary => <<"Get license setting">>,
            description => ?DESC("desc_license_setting_api"),
            responses => #{
                200 => setting()
            }
        },
        put => #{
            tags => ?LICENSE_TAGS,
            summary => <<"Update license setting">>,
            description => ?DESC("desc_license_setting_api"),
            'requestBody' => setting(),
            responses => #{
                200 => setting(),
                400 => emqx_dashboard_swagger:error_codes([?BAD_REQUEST], <<"Bad setting value">>)
            }
        }
    }.

sample_license_info_response() ->
    #{
        customer => "Foo",
        customer_type => 10,
        deployment => "bar-deployment",
        email => "contact@foo.com",
        expiry => false,
        expiry_at => "2295-10-27",
        max_connections => 10,
        start_at => "2022-01-11",
        type => "trial"
    }.

error_msg(Code, Msg) ->
    #{code => Code, message => emqx_utils:readable_error_msg(Msg)}.

%% read license info
'/license'(get, _Params) ->
    License = maps:from_list(emqx_license_checker:dump()),
    {200, License};
%% set/update license
'/license'(post, #{body := #{<<"key">> := Key}}) ->
    case emqx_license:update_key(Key) of
        {error, Error} ->
            ?SLOG(error, #{
                msg => "bad_license_key",
                reason => Error
            }),
            {400, error_msg(?BAD_REQUEST, <<"Bad license key">>)};
        {ok, _} ->
            ?SLOG(info, #{msg => "updated_license_key"}),
            License = maps:from_list(emqx_license_checker:dump()),
            {200, License}
    end;
'/license'(post, _Params) ->
    {400, error_msg(?BAD_REQUEST, <<"Invalid request params">>)}.

'/license/setting'(get, _Params) ->
    {200, maps:remove(<<"key">>, emqx_config:get_raw([license]))};
'/license/setting'(put, #{body := Setting}) ->
    case emqx_license:update_setting(Setting) of
        {error, Error} ->
            ?SLOG(error, #{
                msg => "bad_license_setting",
                reason => Error
            }),
            {400, error_msg(?BAD_REQUEST, <<"Bad license setting">>)};
        {ok, _} ->
            ?SLOG(info, #{msg => "updated_license_setting"}),
            '/license/setting'(get, undefined)
    end.

fields(key_license) ->
    [lists:keyfind(key, 1, emqx_license_schema:fields(key_license))].

setting() ->
    lists:keydelete(key, 1, emqx_license_schema:fields(key_license)).
