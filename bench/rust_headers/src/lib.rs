// Same behaviour as examples/http_headers: log the request line, set one
// response header taken from the JSON plugin configuration.
use proxy_wasm::traits::*;
use proxy_wasm::types::*;

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Trace);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
        Box::new(Root { name: "x-powered-by".into(), value: "moonproxy".into() })
    });
}}

struct Root {
    name: String,
    value: String,
}

impl Context for Root {}

impl RootContext for Root {
    fn on_configure(&mut self, _: usize) -> bool {
        if let Some(raw) = self.get_plugin_configuration() {
            if raw.is_empty() {
                return true;
            }
            let Ok(cfg) = serde_json::from_slice::<serde_json::Value>(&raw) else {
                return false;
            };
            if let Some(h) = cfg.get("header").and_then(|v| v.as_str()) {
                self.name = h.to_lowercase();
            }
            if let Some(v) = cfg.get("value").and_then(|v| v.as_str()) {
                self.value = v.to_string();
            }
        }
        true
    }

    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Stream { name: self.name.clone(), value: self.value.clone() }))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

struct Stream {
    name: String,
    value: String,
}

impl Context for Stream {}

impl HttpContext for Stream {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        let verb = self.get_http_request_header(":method").unwrap_or_else(|| "-".into());
        let path = self.get_http_request_header(":path").unwrap_or_else(|| "-".into());
        log::info!("{} {}", verb, path);
        Action::Continue
    }

    fn on_http_response_headers(&mut self, _: usize, _: bool) -> Action {
        self.set_http_response_header(&self.name, Some(&self.value));
        Action::Continue
    }
}
