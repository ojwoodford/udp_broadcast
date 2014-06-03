%UDP_LISTEN_MEX Return last MATLAB variable received over UDP
%
%   handle = udp_listen_mex(port_num); % Start listening to a port
%   variable = udp_listen_mex(handle); % Get the last heard variable
%   udp_listen_mex(handle); % Destroy the listener
%
%IN:
%   port_num - A port number to broadcast to, between 1024 and 49151.
%   handle - Handle to the internal object created on initialization.
%OUT:
%   variable - Any MATLAB variable which is less that 65508 bytes long when
%              serialized.

function varargout = udp_listen_mex(varargin)
sourceList = {'udp_listen_mex.cpp', '-Xboost', '-llibboost_system-vc100-mt-1_55', '-llibboost_chrono-vc100-mt-1_55', '-llibboost_thread-vc100-mt-1_55'}; % Cell array of compile arguments
[varargout{1:nargout}] = compile(varargin{:}); % Compilation happens here
return