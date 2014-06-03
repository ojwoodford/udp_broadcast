%UDP_BROADCAST Class for UDP broadcasting variables to a particular port
%
%   % Set up the broadcaster
%   hb = udp_broadcast(port); % Broadcast over network (slow)
%   % or
%   hb = udp_broadcast(-port); % Broadcast within local machine only (fast)
%
%   out = broadcast(hb, var, [timeout]); % Broadcast the variable
%IN:
%   hb - Handle to the udp_broadcast class instance.
%   var - MATLAB variable to be broadcast over UDP. This cannot be longer
%         than 65507 bytes when serialized.
%   timeout - Time, in seconds, to wait for previous broadcast to finish
%             before ignoring this broadcast request. Default: 0, i.e. only
%             broadcast if no previous broadcast is in progress.
%
%OUT:
%   out - [numBytes broadcastSuccess].

classdef udp_broadcast < handle
    properties (Hidden = true, Access = private)
        objectHandle; % Handle to C++ object
    end
    
    methods
        %% Constructor
        function broadcastInstance = udp_broadcast(portNum)
            % Check the mex is available - don't attempt to compile here
            % though
            [ext, ext, ext] = fileparts(which('udp_broadcast_mex'));
            if isequal(ext(2:end), mexext)
                % Create the C++ object
                broadcastInstance.objectHandle = udp_broadcast_mex(portNum);
            else
                warning('UDP broadcasting not available. Call ''compile udp_broadcast_mex'' to fix this.');
            end
        end

        %% Destructor
        function delete(broadcastInstance)
            % Destroy the C++ object
            if ~isempty(broadcastInstance.objectHandle)
                udp_broadcast_mex(broadcastInstance.objectHandle);
            end
        end
        
        %% Broadcast variable
        % broadcast(broadcastInstance, variableToSend, timeoutInSeconds)
        function varargout = broadcast(broadcastInstance, varargin)
            if ~isempty(broadcastInstance.objectHandle)
                [varargout{1:nargout}] = udp_broadcast_mex(broadcastInstance.objectHandle, varargin{:});
            end
        end
    end
end