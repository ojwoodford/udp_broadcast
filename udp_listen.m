%UDP_LISTEN Class for listening for UDP messages on a particular port
classdef udp_listen < handle
    properties (Hidden = true, Access = private)
        objectHandle; % Handle to C++ object
    end
    
    methods
        %% Constructor
        function listenInstance = udp_listen(portNum)
            % Create the C++ object
            listenInstance.objectHandle = udp_listen_mex(abs(portNum));
        end

        %% Destructor
        function delete(listenInstance)
            % Destroy the C++ object
            udp_listen_mex(listenInstance.objectHandle);
        end
        
        %% Get the next heard variable
        % If a new variable arrived since the last call, return that.
        % Otherwise wait no more than timeOut seconds for a new message,
        % and return that. If timeOut == 0, don't wait.
        % If no new message is received, return [].
        function var = get(listenInstance, timeOut)
            if nargin < 2
                timeOut = 0; % Get the last heard variable
            end
            var = udp_listen_mex(listenInstance.objectHandle, timeOut);
        end
    end
end