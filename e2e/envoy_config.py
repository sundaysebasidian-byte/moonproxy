"""Builds the Envoy bootstrap used by the end-to-end test and benchmark.

Each HTTP plugin gets its own listener (in front of the echo backend), the
TCP plugin a network-filter listener in front of the TCP echo backend.
"""
import json

ADMIN_PORT = 9901


def _wasm_config(name, wasm_path, config):
    return {
        "name": name,
        "root_id": "",
        "configuration": {
            "@type": "type.googleapis.com/google.protobuf.StringValue",
            "value": json.dumps(config),
        },
        "vm_config": {
            "vm_id": name,
            "runtime": "envoy.wasm.runtime.v8",
            "code": {"local": {"filename": wasm_path}},
        },
        "fail_open": False,
    }


def http_listener(name, port, wasm_path, config, cluster="echo", direct_response=None):
    filters = []
    if wasm_path:
        filters.append({
            "name": "envoy.filters.http.wasm",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm",
                "config": _wasm_config(name, wasm_path, config),
            },
        })
    filters.append({
        "name": "envoy.filters.http.router",
        "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
    })
    return {
        "name": name,
        "address": {"socket_address": {"address": "127.0.0.1", "port_value": port}},
        "filter_chains": [{"filters": [{
            "name": "envoy.filters.network.http_connection_manager",
            "typed_config": {
                "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                "stat_prefix": name,
                "route_config": {"virtual_hosts": [{
                    "name": "all", "domains": ["*"],
                    "routes": [{"match": {"prefix": "/"}, **(
                        {"direct_response": {"status": 200, "body": {"inline_string": direct_response}}}
                        if direct_response is not None else {"route": {"cluster": cluster}})}],
                }]},
                "http_filters": filters,
            },
        }]}],
    }


def tcp_listener(name, port, wasm_path, config):
    return {
        "name": name,
        "address": {"socket_address": {"address": "127.0.0.1", "port_value": port}},
        "filter_chains": [{"filters": [
            {
                "name": "envoy.filters.network.wasm",
                "typed_config": {
                    "@type": "type.googleapis.com/envoy.extensions.filters.network.wasm.v3.Wasm",
                    "config": _wasm_config(name, wasm_path, config),
                },
            },
            {
                "name": "envoy.filters.network.tcp_proxy",
                "typed_config": {
                    "@type": "type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy",
                    "stat_prefix": name, "cluster": "tcp_echo",
                },
            },
        ]}],
    }


def cluster(name, port):
    return {
        "name": name,
        "type": "STATIC",
        "connect_timeout": "1s",
        "load_assignment": {"cluster_name": name, "endpoints": [{"lb_endpoints": [{
            "endpoint": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": port}}},
        }]}]},
    }


def bootstrap(listeners):
    return {
        "admin": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": ADMIN_PORT}}},
        "static_resources": {
            "listeners": listeners,
            # authz_down points at a port nobody listens on (fail-open test).
            "clusters": [cluster("echo", 8081), cluster("authz", 8082), cluster("tcp_echo", 8083),
                         cluster("authz_down", 8089)],
        },
    }
