///|
/// Status codes returned by proxy-wasm host functions (ABI v0.2.1).
#derive(Debug, Eq)
pub(all) enum Status {
  Ok
  NotFound
  BadArgument
  SerializationFailure
  ParseFailure
  InvalidMemoryAccess
  Empty
  CasMismatch
  InternalFailure
  Unimplemented
  Other(Int)
}

///|
pub fn Status::from_int(code : Int) -> Status {
  match code {
    0 => Ok
    1 => NotFound
    2 => BadArgument
    3 => SerializationFailure
    4 => ParseFailure
    6 => InvalidMemoryAccess
    7 => Empty
    8 => CasMismatch
    10 => InternalFailure
    12 => Unimplemented
    c => Other(c)
  }
}

///|
pub fn Status::to_int(self : Status) -> Int {
  match self {
    Ok => 0
    NotFound => 1
    BadArgument => 2
    SerializationFailure => 3
    ParseFailure => 4
    InvalidMemoryAccess => 6
    Empty => 7
    CasMismatch => 8
    InternalFailure => 10
    Unimplemented => 12
    Other(c) => c
  }
}

///|
/// Error raised by the high-level API when a host call does not return `Ok`.
#derive(Debug)
pub suberror HostError {
  HostError(String, Status)
}

///|
pub impl Show for Status with output(self, logger) {
  logger.write_string(
    match self {
      Ok => "Ok"
      NotFound => "NotFound"
      BadArgument => "BadArgument"
      SerializationFailure => "SerializationFailure"
      ParseFailure => "ParseFailure"
      InvalidMemoryAccess => "InvalidMemoryAccess"
      Empty => "Empty"
      CasMismatch => "CasMismatch"
      InternalFailure => "InternalFailure"
      Unimplemented => "Unimplemented"
      Other(c) => "Status(\{c})"
    },
  )
}

///|
pub impl Show for HostError with output(self, logger) {
  let HostError(op, status) = self
  logger.write_string("\{op}: \{status}")
}

///|
/// What the host should do with the current stream after a callback.
#derive(Debug, Eq)
pub(all) enum Action {
  Continue
  Pause
}

///|
pub fn Action::to_int(self : Action) -> Int {
  match self {
    Continue => 0
    Pause => 1
  }
}

///|
#derive(Debug, Eq, Compare)
pub(all) enum LogLevel {
  Trace
  Debug
  Info
  Warn
  Error
  Critical
}

///|
pub fn LogLevel::to_int(self : LogLevel) -> Int {
  match self {
    Trace => 0
    Debug => 1
    Info => 2
    Warn => 3
    Error => 4
    Critical => 5
  }
}

///|
pub fn LogLevel::from_int(level : Int) -> LogLevel {
  match level {
    0 => Trace
    1 => Debug
    2 => Info
    3 => Warn
    4 => Error
    _ => Critical
  }
}

///|
#derive(Debug, Eq, Hash)
pub(all) enum BufferType {
  HttpRequestBody
  HttpResponseBody
  DownstreamData
  UpstreamData
  HttpCallResponseBody
  GrpcReceiveBuffer
  VmConfiguration
  PluginConfiguration
}

///|
pub fn BufferType::to_int(self : BufferType) -> Int {
  match self {
    HttpRequestBody => 0
    HttpResponseBody => 1
    DownstreamData => 2
    UpstreamData => 3
    HttpCallResponseBody => 4
    GrpcReceiveBuffer => 5
    VmConfiguration => 6
    PluginConfiguration => 7
  }
}

///|
#derive(Debug, Eq, Hash)
pub(all) enum MapType {
  HttpRequestHeaders
  HttpRequestTrailers
  HttpResponseHeaders
  HttpResponseTrailers
  GrpcReceiveInitialMetadata
  GrpcReceiveTrailingMetadata
  HttpCallResponseHeaders
  HttpCallResponseTrailers
}

///|
pub fn MapType::to_int(self : MapType) -> Int {
  match self {
    HttpRequestHeaders => 0
    HttpRequestTrailers => 1
    HttpResponseHeaders => 2
    HttpResponseTrailers => 3
    GrpcReceiveInitialMetadata => 4
    GrpcReceiveTrailingMetadata => 5
    HttpCallResponseHeaders => 6
    HttpCallResponseTrailers => 7
  }
}

///|
#derive(Debug, Eq)
pub(all) enum StreamType {
  Request
  Response
  Downstream
  Upstream
}

///|
pub fn StreamType::to_int(self : StreamType) -> Int {
  match self {
    Request => 0
    Response => 1
    Downstream => 2
    Upstream => 3
  }
}

///|
#derive(Debug, Eq)
pub(all) enum MetricType {
  Counter
  Gauge
  Histogram
}

///|
pub fn MetricType::to_int(self : MetricType) -> Int {
  match self {
    Counter => 0
    Gauge => 1
    Histogram => 2
  }
}

///|
#derive(Debug, Eq)
pub(all) enum PeerType {
  Unknown
  Local
  Remote
}

///|
pub fn PeerType::from_int(p : Int) -> PeerType {
  match p {
    1 => Local
    2 => Remote
    _ => Unknown
  }
}

///|
pub impl Show for Action with output(self, logger) {
  logger.write_string(
    match self {
      Continue => "Continue"
      Pause => "Pause"
    },
  )
}

///|
pub impl Show for LogLevel with output(self, logger) {
  logger.write_string(
    match self {
      Trace => "trace"
      Debug => "debug"
      Info => "info"
      Warn => "warn"
      Error => "error"
      Critical => "critical"
    },
  )
}
