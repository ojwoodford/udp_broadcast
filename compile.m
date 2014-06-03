%COMPILE Mex compilation helper function
%
% Examples:
%   compile func1 func2 ... -option1 -option2 ...
%
% This function can be used to (re)compile a number of mex functions, but
% is also a helper function enabling inline compilation.

function varargout = compile(varargin)
% There are two types of call:
% 1. compile('func1', 'func2', ..., [options]).
% 2. [varargout{1:nargout}] = compile(varargin), called from function to
% be compiled.
% Work out which this is

% Try to get the source list
try
    sourceList = evalin('caller', 'sourceList');
catch
    sourceList = [];
end

if iscell(sourceList)
%OJW_MEXCOMPILE_SCRIPT  Compilation helper script for mex files
%
% Should be placed in the m-file of a mexed function, after the
% following lines of code, thus:
%
% function varargout = mymex(varargin)
% sourceList = {'-Iinclude', '-Llib', 'mymex.c', 'mymexhelper.c', '-lmysharedlib'};
% [varargout{1:nargout} = ojw_mexcompile_script(varargin{:});
%
% The script will compile the source inline (i.e. compile & then run) if
% the function has been called without first being compiled.
%
% If varargin{1} == 'compile' and varargin{2} = last_compilation_time,
% then the script calls ojw_mexcompile to compile the function if any of
% the source files have changed since last_compilation_time.
        
    % Get the name of the calling function
    funcName = dbstack('-completenames');
    funcPath = fileparts(funcName(2).file);
    funcName = funcName(2).name;
    
    % Go to the directory containing the file
    currDir = cd(funcPath);
    
    if nargin > 1 && isequal(varargin{1}, 'compile')
        % Standard compilation behaviour
        [varargout{1:nargout}] = ojw_mexcompile(funcName, sourceList, varargin{2:end});
    else
        % Function called without first being compiled
        fprintf('Missing mex file: %s.%s. Will attempt to compile and run.\n', funcName, mexext);
        retval = ojw_mexcompile(funcName, sourceList);
        if retval > 0
            [varargout{1:nargout}] = feval(funcName, varargin{:});
        else
            % Return to the original directory
            cd(currDir);
            
            % Flag the error
            error('Unable to compile %s.', funcName);
        end
    end
    
    % Return to the original directory
    cd(currDir);
    return
end

% Check for compile flags
for a = nargin:-1:1
    M(a) = varargin{a}(1) == '-';
end

me = ['.' mexext];
for a = find(~M(:))'
    % Delete current mex
    s = which(varargin{a});
    if isempty(s)
        error('Function %s not found on the path', varargin{a});
    end
    if strcmp(s(end-numel(me)+1:end), me)
        clear(varargin{a});
        delete(s);
        s = which(varargin{a}); % Refresh the function pointed to
        if strcmp(s(end-numel(me)+1:end), me)
            error('Could not delete the mex file:\n   %s\nEither it is write protected or it is locked in use by MATLAB.', s);
        end
    end
    
    % Compile
    feval(varargin{a}, 'compile', 0, varargin{M});
    % Clear functions and make sure the mex is pointed to
    clear(varargin{a});
    s = which(varargin{a});
    if ~strcmp(s(end-numel(me)+1:end), me)
        error('Compile failed');
    end
end 
end

%OJW_MEXCOMPILE  Mex compile helper function
%
%   okay = ojw_mexcompile(funcName)
%   okay = ojw_mexcompile(..., inputStr)
%   okay = ojw_mexcompile(..., lastCompiled)
%
% Compile mexed function, given an optional list of source files and other
% compile options. Can optionally check if source files have been modified
% since the last compilation, and only compile if they have.
%
%IN:
%   funcName - string containg the name of the function to compile
%   inputStr - cell array of input strings to be passed to mex, e.g. source
%              file names, include paths, library paths, optimizer flags,
%              etc. Default: {[funcName '.c']}.
%   lastCompiled - datenum of the current mex file. Default: 0 (i.e. force
%                  compilation).
%
%OUT:
%   okay - 1: function compiled; 0: up-to-date, no need to compile; -1:
%          compilation failed.

function okay = ojw_mexcompile(funcName, varargin)

% Determine architecture
is64bit = mexext;
is64bit = strcmp(is64bit(end-1:end), '64');

% Set defaults for optional inputs
sourceList = [funcName '.c'];
lastCompiled = 0;
% Parse inputs
extraOptions = {};
for a = 1:numel(varargin)
    if iscell(varargin{a}) && ischar(varargin{a}{1})
        sourceList = varargin{a};
    elseif isnumeric(varargin{a}) && isscalar(varargin{a})
        lastCompiled = varargin{a};
    elseif ischar(varargin{a})
        extraOptions = [extraOptions varargin(a)];
    end
end
sourceList = [sourceList extraOptions];

okay = 0;
if lastCompiled
    compile = false;
    % Compile if current mex file is older than any of the source files
    % Note: this doesn't consider included files (e.g. header files)
    for a = 1:numel(sourceList)
        dirSource = dir(sourceList{a});
        if ~isempty(dirSource)
            if datenum(dirSource.date) > lastCompiled
                compile = true;
                break;
            end
        end
    end
else
    compile = true;
end

% Exit if not compiling
if ~compile
    return;
end
okay = -1;

debug = false;
cudaOptions = cell(0, 1);
%L = {''};
% Parse the compile options
for a = 1:numel(sourceList)
    if sourceList{a}(1) == '-' % Found an option (not a source file)
        switch sourceList{a}(2)
            case 'N' % Cuda nvcc option
                cudaOptions{end+1} = sourceList{a}(3:end);
                sourceList{a} = '';
            case 'g' % Debugging on
                debug = debug | (numel(sourceList{a}) == 2);
        end
    end
end

L = zeros(numel(sourceList), 1);
gpucc = [];
% Convert any CUDA files to C++, and any Fortran files to object files
for a = 1:numel(sourceList)
    if isempty(sourceList{a}) || sourceList{a}(1) == '-' % Found an option (not a source file)
        continue;
    end
    [ext ext ext] = fileparts(sourceList{a});
    switch ext
        case '.cu'
            % GPU programming - Convert any *.cu files to *.cpp
            if isempty(gpucc)
                % Create nvcc call
                cudaDir = cuda_path;
                cudaSDKdir = cuda_sdk;
                gpucc = sprintf('"%s%s" -D_MATLAB_ -I"%s%sextern%sinclude" -I"%sinc" -m%d', cudaDir, nvcc, matlabroot, filesep, filesep, cudaSDKdir, 32*(1+is64bit));
                % Add cuda specific options
                if ~isempty(cudaOptions)
                    gpucc = [gpucc sprintf(' %s', cudaOptions{:})];
                end
                if ispc && is64bit
                    cc = mex.getCompilerConfigurations();
                    gpucc = [gpucc ' -ccbin "' cc.Location '\VC\bin" -I"' cc.Location '\VC\include"'];
                end
                % Add any include directories from source list and cuda
                % specific options
                for b = 1:numel(sourceList)
                    if strcmp(sourceList{b}(1:min(2, end)), '-I')
                        gpucc = [gpucc ' ' sourceList{b}];
                    end
                end
                % Add the debug flag
                if debug
                    gpucc = [gpucc ' -g -G0 -UNDEBUG -DDEBUG'];
                end
            end
            % Compile to C++ source file
            outName = [tempname '.cpp'];
            cmd = sprintf('%s --cuda "%s" --output-file "%s"', gpucc, sourceList{a}, outName);
            disp(cmd);
            if system(cmd)
                % Quit
                fprintf('ERROR while converting %s to %s.\n', sourceList{a}, outName);
                clean_up(sourceList(L == 1));
                return;
            end
            sourceList{a} = outName;
            L(a) = 1;
        case {'.f', '.f90'}
            L(a) = 2;
    end
    sourceList{a} = ['"' sourceList{a} '"'];
end

% Set up special options and put in the list of input commands
a = 1;
while a <= numel(sourceList)
    if numel(sourceList{a}) > 2 && isequal(sourceList{a}(1:2), '-X')
        % Special option
        flags = feval(sourceList{a}(3:end));
        % Merge cell array into the list
        if iscell(flags)
            sourceList(a:end+numel(flags)-1) = [flags sourceList(a+1:end)];
            a = a + numel(flags);
        else
            sourceList{a} = flags;
            a = a + 1;
        end
    else
        a = a + 1;
    end
end

% Set the compiler flags
if debug
    flags = {'-UNDEBUG', '-DDEBUG'};
else
    flags = {'-O'};
end
flags = [flags {['-I"' cd() '"']}];
if any(L == 1)
    flags = [flags cuda];
end
switch mexext
    case {'mexglx', 'mexa64'}
        if ~debug
            str = '"-O3 -ffast-math -funroll-loops"';
            flags(end+1:end+3) = {sprintf('CXXOPTIMFLAGS=%s', str), sprintf('LDCXXOPTIMFLAGS=%s', str), sprintf('LDOPTIMFLAGS=%s', str)};
        end
    case {'mexw32', 'mexw64'}
        flags{end+1} = 'OPTIMFLAGS="$OPTIMFLAGS"';
    otherwise
end

% Call mex to compile the code
cmd = sprintf('mex -D_MATLAB_%s%s -output "%s"', sprintf(' %s', flags{:}), sprintf(' %s', sourceList{:}), funcName);
disp(cmd);
try
    eval(cmd);
    okay = 1;
catch me
    fprintf('ERROR while compiling %s\n', funcName);
    %fprintf('%s', getReport(me));
end

% Clean up
clean_up(sourceList(L == 1));
end

function clean_up(sourceList)
% Delete the intermediate files
for a = 1:numel(sourceList)
    delete(sourceList{a}(2:end-1));
end
end

function cuda_path_str = cuda_path
cuda_path_str = user_string('cuda_path');
if ~check_path()
    % Check the environment variables
    cuda_path_str = getenv('CUDA_PATH');
    if check_path()
        user_string('cuda_path', cuda_path_str);
        return;
    end
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select cuda base software installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            break;
        end
        cuda_path_str = [path_str filesep];
        if check_path()
            user_string('cuda_path', cuda_path_str);
            return;
        end
    end
    error('Cuda not found.');
end
% Nested function
    function good = check_path
        % Check the path is valid
        [good message] = system(sprintf('"%s%s" -h', cuda_path_str, nvcc));
        good = good == 0;
    end
end

function path = nvcc
path = ['bin' filesep 'nvcc'];
if ispc
    path = [path '.exe'];
end
end

function cuda_sdk_path_str = cuda_sdk
cuda_sdk_path_str = user_string('cuda_sdk_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select Cuda SDK base installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            break;
        end
        cuda_sdk_path_str = [path_str filesep 'C' filesep 'common' filesep];
        if check_path()
             user_string('cuda_sdk_path', cuda_sdk_path_str);
            return;
        end
    end
    warning('Cuda SDK not found.');
end
% Nested function
    function good = check_path
        % Check the path is valid
        good = exist([cuda_sdk_path_str 'inc' filesep 'cutil.h'], 'file');
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%% SPECIAL OPTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Create the compiler options for cuda
function flags = cuda
% Set gpu code compiler & linker flags
is64bit = mexext;
is64bit = strcmp(is64bit(end-1:end), '64');
bitStr = {'32', '', '64', 'Win32', 'x64'};
cudaDir = cuda_path;
cudaSDKdir = cuda_sdk;
flags = {sprintf('-I"%sinclude"', cudaDir), sprintf('-I"%sinc"', cudaSDKdir), sprintf('-L"%slib/%s"', cudaDir, bitStr{4+is64bit}), '-lcudart'};
end

% Create the compiler options for lapack/blas
function flags = lapack
flags = {'-lmwlapack', '-lmwblas'}; % Use MATLAB's versions
end

% Create the compiler options for OpenMP
function flags = openmp
flags = {'COMPFLAGS="/openmp', '$COMPFLAGS"'};
end

% Create the compiler options for OpenCV
function flags = opencv
opencv_path_str = user_string('opencv_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select your OpenCV installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            error('OpenCV not found.');
        end
        opencv_path_str = [path_str filesep];
        if check_path()
            user_string('opencv_path', opencv_path_str);
            break;
        end
    end
end
flags = {sprintf('-I"%sinclude/opencv"', opencv_path_str),  sprintf('-L"%slib"', opencv_path_str), '-lcv210', '-lcvaux210', '-lcxcore210'};
% Nested function
    function good = check_path
        % Check the path is valid
        if ispc
            good = exist([opencv_path_str 'cvconfig.h.cmake'], 'file');
        else
            good = exist([opencv_path_str 'cvconfig.h.in'], 'file');
        end
    end
end

% Add the boost library directory
function flags = boost
boost_path_str = user_string('boost_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select your Boost installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            error('Boost not found.');
        end
        boost_path_str = path_str;
        if check_path()
            user_string('boost_path', boost_path_str);
            break;
        end
    end
end
bitStr = mexext;
if strcmp(bitStr(end-1:end), '64')
    bitStr = '64';
else
    bitStr = '';
end
flags = {sprintf('-I"%s"', boost_path_str), sprintf('-L"%s%slib%s"', boost_path_str, filesep, bitStr)};
% Nested function
    function good = check_path
        % Check the path is valid
        good = exist(sprintf('%s%sboost%sshared_ptr.hpp', boost_path_str, filesep, filesep), 'file');
    end
end

% Add the eigen library directory
function str = eigen
eigen_path_str = user_string('eigen_path');
if ~check_path()
    % Check the environment variables
    eigen_path_str = getenv('EIGEN_DIR');
    if check_path()
        user_string('eigen_path', eigen_path_str);
    else
        % Ask the user to enter the path
        while 1
            path_str = uigetdir('/', 'Please select your Eigen installation directory.');
            if isequal(path_str, 0)
                % User hit cancel or closed window
                error('Eigen not found.');
            end
            eigen_path_str = path_str;
            if check_path()
                user_string('eigen_path', eigen_path_str);
                break;
            end
        end
    end
end
str = sprintf('-I"%s"', eigen_path_str);
% Nested function
    function good = check_path
        % Check the path is valid
        good = exist(sprintf('%s%sEigen%sCore', eigen_path_str, filesep, filesep), 'file');
    end
end

% Add the directX library directory
function str = directx
directx_path_str = user_string('directx_sdk_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select your DirectX SDK installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            error('DirectX SDK not found.');
        end
        directx_path_str = [path_str filesep];
        if check_path()
            user_string('directx_sdk_path', directx_path_str);
            break;
        end
    end
end
str = sprintf('-L"%sLib%sx%d"', directx_path_str, filesep, 86-22*is64bit());
% Nested function
    function good = check_path
        % Check the path is valid
        if ispc
            good = exist(sprintf('%sLib%sx86%sdxguid.lib', directx_path_str, filesep, filesep), 'file');
        else
            error('DirectX only supported on Windows');
        end
    end
end
