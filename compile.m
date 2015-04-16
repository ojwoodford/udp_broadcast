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
            which(funcName); % Make sure MATLAB registers the new function
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
            case 'X' % Special option
                sourceList{a} = feval(sourceList{a}(3:end), debug);
            case 'g' % Debugging on
                debug = debug | (numel(sourceList{a}) == 2);
        end
    else
        sourceList{a} = ['"' sourceList{a} '"'];
    end
end

L = zeros(numel(sourceList), 1);
gpucc = [];
options_file = [];
% Convert any CUDA files to C++, and any Fortran files to object files
for a = 1:numel(sourceList)
    if isempty(sourceList{a}) || sourceList{a}(1) == '-' % Found an option (not a source file)
        continue;
    end
    [ext, ext, ext] = fileparts(sourceList{a}(2:end-1));
    switch ext
        case '.cu'
            % GPU programming - Convert any *.cu files to *.cpp
            if isempty(gpucc)
                % Create nvcc call
                cudaDir = cuda_path();
                options_file = ['"' tempname '.txt"'];
                fid = fopen(options_file(2:end-1), 'wt'); 
                gpucc = sprintf('"%s%s" --options-file %s', cudaDir, nvcc(), options_file);
                fprintf(fid, ' -D_MATLAB_ -I"%s%sextern%sinclude" -m%d', matlabroot, filesep, filesep, 32*(1+is64bit));
                % Add cuda specific options
                if ~isempty(cudaOptions)
                    fprintf(fid, ' %s', cudaOptions{:});
                end
                if ispc && is64bit
                    cc = mex.getCompilerConfigurations();
                    fprintf(fid, ' -ccbin "%s\\VC\\bin" -I"%s\\VC\\include"', cc.Location, cc.Location);
                end
                % Add any include directories from source list and cuda
                % specific options
                for b = 1:numel(sourceList)
                    if strcmp(sourceList{b}(1:min(2, end)), '-I')
                        fprintf(fid, ' %s', sourceList{b});
                    end
                end
                % Add the debug flag
                if debug
                    fprintf(fid, ' -g -UNDEBUG -DDEBUG');
                else
                    % Apply optimizations
                    fprintf(fid, ' -O3 --use_fast_math');
                end
                fclose(fid);
            end
            % Compile to object file
            outName = ['"' tempname '.o"'];
            cmd = sprintf('%s --compile "%s" --output-file %s', gpucc, sourceList{a}, outName);
            disp(cmd);
            if system(cmd)
                % Quit
                fprintf('ERROR while converting %s to %s.\n', sourceList{a}, outName);
                clean_up([reshape(sourceList(L == 1), [], 1); {options_file}]);
                return;
            end
            sourceList{a} = outName;
            L(a) = 1;
        case {'.f', '.f90'}
            L(a) = 2;
    end
end
% Delete the options file
if ~isempty(options_file)
    delete(options_file(2:end-1));
    options_file = [];
end

% Set the compiler flags
if debug
    flags = '-UNDEBUG -DDEBUG';
else
    flags = '-O -DNDEBUG';
end
if any(L == 1)
    flags = [flags ' ' cuda(debug)];
end
switch mexext
    case {'mexglx', 'mexa64'}
        if ~debug
            str = '"-O3 -ffast-math -funroll-loops"';
            flags = sprintf('%s CXXOPTIMFLAGS=%s LDCXXOPTIMFLAGS=%s LDOPTIMFLAGS=%s', flags, str, str, str);
        end
    otherwise
end

% Call mex to compile the code
cmd = sprintf('mex -D_MATLAB_=%d %s%s -output "%s"', [100 1] * sscanf(version(), '%d.%d', 2), flags, sprintf(' %s', sourceList{:}), funcName);
disp(cmd);
try
    eval(cmd);
    okay = 1;
catch me
    fprintf('ERROR while compiling %s\n', funcName);
    fprintf('%s', getReport(me, 'basic'));
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

function cuda_path_str = cuda_path()
cuda_path_str = user_string('cuda_path');
if ~check_path()
    % Check the environment variables
    cuda_path_str = fullfile(getenv('CUDA_PATH'), '/');
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
        [good, message] = system(sprintf('"%s%s" -h', cuda_path_str, nvcc()));
        good = good == 0;
    end
end

function path_ = nvcc()
path_ = ['bin' filesep 'nvcc'];
if ispc
    path_ = [path_ '.exe'];
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
function str = cuda(debug)
% Set gpu code compiler & linker flags
is64bit = mexext;
is64bit = strcmp(is64bit(end-1:end), '64');
bitStr = {'32', '', '64', 'Win32', 'x64'};
cudaDir = cuda_path();
str = sprintf('-I"%sinclude" -L"%slib/%s" -lcudart', cudaDir, cudaDir, bitStr{4+is64bit});
end

function str = cudasdk(debug)
str = sprintf('-I"%sinc"', cuda_sdk);
end

% Create the compiler options for lapack/blas
function str = lapack(debug)
str = '-lmwlapack -lmwblas'; % Use MATLAB's versions
end

% Create the compiler options for OpenMP
function str = openmp(debug)
if debug
    str = '';
else
    str = 'COMPFLAGS="/openmp $COMPFLAGS"';
end
end

% Create the compiler options for OpenCV
function str = opencv(debug)
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
str = sprintf('-I"%sinclude/opencv" -L"%slib" -lcv210 -lcvaux210 -lcxcore210', opencv_path_str, opencv_path_str);
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
function str = boost(debug)
boost_path_str = user_string('boost_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select your Boost installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            error('Boost not found.');
        end
        boost_path_str = [path_str filesep];
        if check_path()
            user_string('boost_path', boost_path_str);
            break;
        end
    end
end
str = sprintf('-I"%s" -L"%sstage%slib%s"', boost_path_str, boost_path_str, filesep, filesep);
% Nested function
    function good = check_path
        % Check the path is valid
        good = exist(sprintf('%sboost%sshared_ptr.hpp', boost_path_str, filesep), 'file');
    end
end

% Add the directX library directory
function str = directx(debug)
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

% Add the Eigen library directory
function str = eigen(debug)
eigen_path_str = user_string('eigen_path');
if ~check_path()
    % Ask the user to enter the path
    while 1
        path_str = uigetdir('/', 'Please select your Eigen installation directory.');
        if isequal(path_str, 0)
            % User hit cancel or closed window
            error('Eigen not found.');
        end
        eigen_path_str = [path_str filesep];
        if check_path()
            user_string('eigen_path', eigen_path_str);
            break;
        end
    end
end
str = sprintf('-I"%s"', eigen_path_str);
if ~debug
    str = [str ' -DEIGEN_NO_DEBUG'];
end
% Nested function
    function good = check_path
        % Check the path is valid
        good = exist(sprintf('%sEigen%sCore', eigen_path_str, filesep), 'file');
    end
end
