%UDP_BROADCAST_MEX Broadcast a single MATLAB variable using UDP
%
%   handle = udp_broadcast_mex(port_num); % Open the port
%   udp_broadcast_mex(handle, variable); % Broadcast a variable
%   udp_broadcast_mex(handle); % Close the port
%
%IN:
%   port_num - A port number to broadcast to, between 1024 and 49151.
%              Negate the port_num to transmit only to the local PC.
%   variable - Any MATLAB variable which is less that 65508 bytes long when
%              serialized.
%   handle - Handle to the internal object created on initialization.

function varargout = udp_broadcast_mex(varargin)
sourceList = {'udp_broadcast_mex.cpp', '-Xboost', '-llibboost_system-vc100-mt-1_55', '-llibboost_chrono-vc100-mt-1_55', '-llibboost_thread-vc100-mt-1_55'}; % Cell array of compile arguments
[varargout{1:nargout}] = compile(varargin{:}); % Compilation happens here
return