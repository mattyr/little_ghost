# frozen_string_literal: true

require "ipaddr"

module LittleGhost
  module Network
    # Builds Envoy v3 configuration for exact-destination CONNECT filtering and
    # optional TLS-intercepted external authorization.
    module EnvoyConfig # :nodoc:
      TYPE_URL = "type.googleapis.com/"
      DOMAIN = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
      BLOCKED_DESTINATIONS = [
        ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
        ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
        ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24],
        ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
        ["::", 128], ["::1", 128], ["::ffff:0:0", 96], ["64:ff9b::", 96],
        ["64:ff9b:1::", 48], ["100::", 64], ["2001::", 23], ["2002::", 16],
        ["fc00::", 7], ["fec0::", 10], ["fe80::", 10], ["ff00::", 8]
      ].freeze

      module_function

      def build(policy:, listener:, paths: {})
        endpoints = endpoints(policy.allow)
        if policy.inspection == :http
          build_http(policy:, endpoints:, listener:, paths:)
        else
          build_connect(endpoints:, listener:, access_log: paths[:access_log])
        end
      end

      def endpoints(values)
        parsed = Array(values).map { |value| parse_endpoint(value) }
        raise PolicyError, "network allowlist must contain at least one destination" if parsed.empty?
        raise PolicyError, "network allowlist destinations must be unique" if parsed.uniq.length != parsed.length

        parsed.freeze
      end

      def parse_endpoint(value)
        supplied = String(value)
        match = supplied.match(/\A(.+):(\d+)\z/)
        raise PolicyError, "network allowlist entries must use exact host:port syntax" unless match

        host = match[1]
        port = Integer(match[2], 10)
        unless DOMAIN.match?(host) && host == host.downcase && !ip_address?(host) && port.between?(1, 65_535)
          raise PolicyError, "network allowlist entries must use exact lowercase DNS names and valid ports"
        end
        [host.freeze, port].freeze
      end

      def build_connect(endpoints:, listener:, access_log: nil)
        routes = endpoints.map do |host, port|
          {
            "match" => {
              "connect_matcher" => {},
              "headers" => [{"name" => ":authority", "string_match" => {"exact" => "#{host}:#{port}"}}]
            },
            "route" => {
              "cluster" => "little_ghost_egress",
              "timeout" => "0s",
              "upgrade_configs" => [{"upgrade_type" => "CONNECT", "connect_config" => {}}]
            }
          }
        end
        routes << {"match" => {"connect_matcher" => {}}, "direct_response" => {"status" => 403}}
        routes << {"match" => {"prefix" => "/"}, "direct_response" => {"status" => 403}}
        filters = [dynamic_forward_proxy_filter, router_filter]
        {
          "static_resources" => {
            "listeners" => [http_listener(
              name: "little_ghost_explicit_proxy",
              address: listener,
              route_config: route_config("little_ghost_connect", routes),
              filters:,
              connect: true,
              access_log:
            )],
            "clusters" => [dynamic_forward_proxy_cluster(tls: false)]
          }
        }
      end

      def build_http(policy:, endpoints:, listener:, paths:)
        unless endpoints.all? { |_host, port| port == 443 }
          raise PolicyError, "HTTP inspection supports only TLS destinations on port 443"
        end
        required = %i[interceptor_socket authorizer_socket certificate_chain private_key trusted_ca]
        missing = required.reject { |name| paths[name] }
        raise PolicyError, "HTTP inspection is missing #{missing.join(", ")}" unless missing.empty?
        raise PolicyError, "HTTP inspection requires an authorizer" unless policy.authorizer

        outer_routes = endpoints.map do |host, port|
          {
            "match" => {
              "connect_matcher" => {},
              "headers" => [{"name" => ":authority", "string_match" => {"exact" => "#{host}:#{port}"}}]
            },
            "route" => {
              "cluster" => "little_ghost_tls_interceptor",
              "timeout" => "0s",
              "upgrade_configs" => [{"upgrade_type" => "CONNECT", "connect_config" => {}}]
            }
          }
        end
        outer_routes << {"match" => {"connect_matcher" => {}}, "direct_response" => {"status" => 403}}
        outer_routes << {"match" => {"prefix" => "/"}, "direct_response" => {"status" => 403}}
        inner_virtual_hosts = endpoints.map do |host, port|
          {
            "name" => "host_#{host.tr(".-", "__")}",
            "domains" => [host, "#{host}:#{port}"],
            "routes" => [{
              "match" => {"prefix" => "/"},
              "route" => {"cluster" => "little_ghost_egress", "timeout" => "0s"},
              "typed_per_filter_config" => {
                "envoy.filters.http.dynamic_forward_proxy" => typed(
                  "envoy.extensions.filters.http.dynamic_forward_proxy.v3.PerRouteConfig",
                  host_rewrite_literal: host
                )
              },
              "response_headers_to_remove" => ["set-cookie", "set-cookie2"]
            }]
          }
        end
        interceptor_listener = {
          "name" => "little_ghost_tls_interceptor",
          "address" => pipe_address(paths.fetch(:interceptor_socket), 0o600),
          "filter_chains" => [{
            "transport_socket" => {
              "name" => "envoy.transport_sockets.tls",
              "typed_config" => typed(
                "envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext",
                common_tls_context: {
                  "tls_params" => {"tls_minimum_protocol_version" => "TLSv1_2"},
                  "tls_certificates" => [{
                    "certificate_chain" => {"filename" => paths.fetch(:certificate_chain)},
                    "private_key" => {"filename" => paths.fetch(:private_key)}
                  }]
                }
              )
            },
            "filters" => [{
              "name" => "envoy.filters.network.http_connection_manager",
              "typed_config" => hcm(
                route_config: {
                  "name" => "little_ghost_upstream_routes",
                  "virtual_hosts" => inner_virtual_hosts
                },
                filters: [authorizer_filter(policy.forward_headers, policy.mutation_headers), dynamic_forward_proxy_filter, router_filter],
                access_log: paths[:access_log]
              )
            }]
          }]
        }
        {
          "static_resources" => {
            "listeners" => [
              http_listener(
                name: "little_ghost_explicit_proxy",
                address: listener,
                route_config: route_config("little_ghost_connect", outer_routes),
                filters: [router_filter],
                connect: true
              ),
              interceptor_listener
            ],
            "clusters" => [
              unix_cluster("little_ghost_tls_interceptor", paths.fetch(:interceptor_socket)),
              unix_cluster("little_ghost_authorizer", paths.fetch(:authorizer_socket)),
              dynamic_forward_proxy_cluster(tls: true, trusted_ca: paths.fetch(:trusted_ca))
            ]
          }
        }
      end

      def dns_cache_config
        {
          "name" => "little_ghost_egress_dns",
          "dns_lookup_family" => "ALL",
          "max_hosts" => 256,
          "dns_query_timeout" => "5s",
          "dns_cache_circuit_breaker" => {"max_pending_requests" => 64},
          "resolved_address_filter" => {
            "ranges" => BLOCKED_DESTINATIONS.map do |address, prefix|
              {"address_prefix" => address, "prefix_len" => prefix}
            end
          }
        }
      end

      def dynamic_forward_proxy_cluster(tls:, trusted_ca: nil)
        cluster = {
          "name" => "little_ghost_egress",
          "connect_timeout" => "15s",
          "lb_policy" => "CLUSTER_PROVIDED",
          "circuit_breakers" => {
            "thresholds" => [{
              "priority" => "DEFAULT",
              "max_connections" => 128,
              "max_pending_requests" => 128,
              "max_requests" => 256,
              "max_retries" => 0
            }]
          },
          "cluster_type" => {
            "name" => "envoy.clusters.dynamic_forward_proxy",
            "typed_config" => typed(
              "envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig",
              dns_cache_config: dns_cache_config
            )
          }
        }
        if tls
          cluster["transport_socket"] = {
            "name" => "envoy.transport_sockets.tls",
            "typed_config" => typed(
              "envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext",
              common_tls_context: {
                "tls_params" => {"tls_minimum_protocol_version" => "TLSv1_2"},
                "validation_context" => {"trusted_ca" => {"filename" => trusted_ca}}
              }
            )
          }
        end
        cluster
      end

      def http_listener(name:, address:, route_config:, filters:, connect: false, access_log: nil)
        {
          "name" => name,
          "address" => address,
          "listener_filters" => [{
            "name" => "envoy.filters.listener.http_inspector",
            "typed_config" => typed("envoy.extensions.filters.listener.http_inspector.v3.HttpInspector")
          }],
          "filter_chains" => [{"filters" => [{
            "name" => "envoy.filters.network.http_connection_manager",
            "typed_config" => hcm(route_config:, filters:, connect:, access_log:)
          }]}]
        }
      end

      def hcm(route_config:, filters:, connect: false, access_log: nil)
        config = typed(
          "envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
          stat_prefix: "little_ghost_egress",
          codec_type: "AUTO",
          max_request_headers_kb: 8,
          stream_error_on_invalid_http_message: true,
          route_config:,
          http_filters: filters
        )
        config["upgrade_configs"] = [{"upgrade_type" => "CONNECT"}] if connect
        if access_log
          config["access_log"] = [{
            "name" => "envoy.access_loggers.file",
            "typed_config" => typed(
              "envoy.extensions.access_loggers.file.v3.FileAccessLog",
              path: access_log,
              log_format: {
                "text_format_source" => {
                  "inline_string" => "%START_TIME% %REQ(:METHOD)% %REQ(:AUTHORITY)% %RESPONSE_CODE% %RESPONSE_FLAGS% %UPSTREAM_HOST% %BYTES_RECEIVED% %BYTES_SENT% %DURATION%\n"
                }
              }
            )
          }]
        end
        config
      end

      def authorizer_filter(forward_headers, mutation_headers)
        patterns = Array(forward_headers).map { |name| {"exact" => name} }
        authorization_request = patterns.empty? ? {} : {"allowed_headers" => {"patterns" => patterns}}
        authorization_response = {
          "allowed_client_headers" => {"patterns" => [{"exact" => "content-type"}]}
        }
        unless mutation_headers.empty?
          authorization_response["allowed_upstream_headers"] = {
            "patterns" => mutation_headers.map { |name| {"exact" => name} }
          }
        end
        {
          "name" => "envoy.filters.http.ext_authz",
          "typed_config" => typed(
            "envoy.extensions.filters.http.ext_authz.v3.ExtAuthz",
            failure_mode_allow: false,
            status_on_error: {code: "ServiceUnavailable"},
            validate_mutations: true,
            disallowed_headers: {
              "patterns" => %w[authorization proxy-authorization cookie].map { |name| {"exact" => name} }
            },
            http_service: {
              "server_uri" => {
                "uri" => "http://little-ghost-authorizer",
                "cluster" => "little_ghost_authorizer",
                "timeout" => "5s"
              },
              "authorization_request" => authorization_request,
              "authorization_response" => authorization_response
            }
          )
        }
      end

      def dynamic_forward_proxy_filter
        {
          "name" => "envoy.filters.http.dynamic_forward_proxy",
          "typed_config" => typed(
            "envoy.extensions.filters.http.dynamic_forward_proxy.v3.FilterConfig",
            dns_cache_config: dns_cache_config
          )
        }
      end

      def router_filter
        {
          "name" => "envoy.filters.http.router",
          "typed_config" => typed("envoy.extensions.filters.http.router.v3.Router")
        }
      end

      def route_config(name, routes)
        {"name" => name, "virtual_hosts" => [{"name" => name, "domains" => ["*"], "routes" => routes}]}
      end

      def unix_cluster(name, path)
        {
          "name" => name,
          "type" => "STATIC",
          "connect_timeout" => "5s",
          "load_assignment" => {
            "cluster_name" => name,
            "endpoints" => [{
              "lb_endpoints" => [{"endpoint" => {"address" => {"pipe" => {"path" => path}}}}]
            }]
          }
        }
      end

      def pipe_address(path, mode = 0o600)
        {"pipe" => {"path" => path, "mode" => mode}}
      end

      def socket_address(host, port)
        {"socket_address" => {"address" => host, "port_value" => port}}
      end

      def typed(name, **values)
        {"@type" => "#{TYPE_URL}#{name}", **values.transform_keys(&:to_s)}
      end

      def ip_address?(value)
        IPAddr.new(value)
        true
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
