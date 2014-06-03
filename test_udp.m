function test_udp(val)
if nargin > 0 && isscalar(val)
    % Receiver mode - i.e. this is the second instance of MATLAB, started
    % automatically
    % Set up listening thread
    hl = udp_listen(12347);
    if val
        % Get ready to broadcast
        hb = udp_broadcast(12346);
    end
    % Get the message - waiting for 10 seconds
    val2 = get(hl, 10);
    if val
        % Send the message back
        broadcast(hb, val2);
    end
    return
end

if nargin == 0
    % Generate random matrix to send
    val = rand(90);
end

% First check local send and receive
% Set up listening thread
hl = udp_listen(12347);
% Get ready to broadcast
hb = udp_broadcast(12347);
% Broadcast the data
tic;
t0 = broadcast(hb, val);
t1 = toc;
pause(1);
tic;
val2 = get(hl, 0);
t2 = toc;
if isempty(val2)
    error('Timed out waiting for message');
end
% Check the data is the same
assert(isequal(val, val2));
% Clear variables
clear hl val2
% All good!
fprintf('Local test passed! For a %d byte message - Broadcast time: %gs; Listen time: %gs.\n', t0(1), t1, t2);

% Now check inter-prcess communication
% Set up listening thread
hl = udp_listen(12346);
% Start a MATLAB to receive the message
[a, a] = system('matlab -automation -r "test_udp(0); quit();" &');
% Start another MATLAB to receive and resend the message
[a, a] = system('matlab -automation -r "test_udp(1); quit();" &');
% Start another MATLAB to receive the message
[a, a] = system('matlab -automation -r "test_udp(0); quit();" &');
% Wait for the other end to be ready
pause(7);
% Broadcast the data
tic;
t0 = broadcast(hb, val);
t1 = toc;
% Wait for 10 seconds for the data to come back
pause(10);
tic;
val2 = get(hl, 0);
t2 = toc;
if isempty(val2)
    error('Timed out waiting for message');
end
% Check the data is the same
assert(isequal(val, val2));
% Clear the C++ objects
clear hb hl
% All good!
fprintf('Inter-process test passed! For a %d byte message - Broadcast time: %gs; Listen time: %gs.\n', t0(1), t1, t2);