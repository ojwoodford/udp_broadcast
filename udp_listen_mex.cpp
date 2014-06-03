#include <stdint.h>
#include <stdio.h>
#include <vector>

#define BOOST_DATE_TIME_NO_LIB
#define BOOST_REGEX_NO_LIB
#include <boost/asio.hpp>
#include <boost/chrono.hpp>
#include <boost/thread.hpp>

#ifdef _MATLAB_
#include "mex.h"
#include "handle_class.h"
extern "C" mxArray* mxDeserialize(const void*, size_t);
#endif

class udp_listen {
public:
    // Constructor
    udp_listen(int port) {
        // Set the port number
        port_m = port;
        // Make sure we have no message to start
        messageLength_m = 0;
        // Create the looping thread
        hThread_m = boost::thread(&(this->udp_listener_thread), this);
    }
    // Destructor
    ~udp_listen() {
        // Signal the thread to end
        port_m = -1;
        // Wait for it to die
        hThread_m.join();
    }

	// Write the message into a buffer
	void get_message(std::vector<uint8_t> &out, double timeout)
	{
		// Wait for a new message
        message_wait(timeout);
		get_lock(); // Grab the buffer lock
		// Copy into the vector
		out.resize(messageLength_m);
		memcpy(&out[0], buffer_m, messageLength_m);
        messageLength_m = 0; // Mark message as read
		release_lock(); // Release the lock
	}

	// Write the message into a fixed length buffer
	int get_message(uint8_t *out, int maxLen, double timeout)
	{
		// Wait for a new message
        message_wait(timeout);
		get_lock(); // Grab the buffer lock
		// Copy into the buffer
		int len = messageLength_m > maxLen ? maxLen : messageLength_m;
		memcpy(out, buffer_m, len);
        messageLength_m = 0; // Mark message as read
		release_lock(); // Release the lock
		return len;
	}
    
#ifdef _MATLAB_
    // Get the message as a MATLAB array
    mxArray *get_message(double timeout) {
        // Wait for a new message
        message_wait(timeout);            
        mxArray *array;
        get_lock(); // Grab the buffer lock
        if (messageLength_m)
            array = mxDeserialize(buffer_m, messageLength_m);
        else
            array = mxCreateNumericMatrix(0, 0, mxDOUBLE_CLASS, mxREAL);
        messageLength_m = 0; // Mark message as read
        release_lock(); // Release the lock
        return array;
    }
#endif
    
private:
    // Port number - also used for killing the thread
    volatile int port_m;
    // Functions for avoiding simultaneous access to the buffer
    void get_lock() { hMutex_m.lock(); }
    void release_lock() { hMutex_m.unlock(); }
    // Functions for efficient waiting for messages
    void message_event() {  boost::mutex::scoped_lock lock(hEventMutex_m); hEvent_m.notify_all(); }
    void message_wait(double timeout) { boost::mutex::scoped_lock lock(hEventMutex_m); hEvent_m.timed_wait(lock, boost::posix_time::milliseconds(int(timeout*1000.0))); }
    // Buffer for storing the data in
    uint8_t buffer_m[65535]; // Maximum UDP message size
    size_t messageLength_m;
    
    // Thread variables
    boost::thread hThread_m;
    boost::timed_mutex hMutex_m;
    boost::condition_variable hEvent_m;
    boost::mutex hEventMutex_m;
    
    // This thread loops continuously in the background, reading messages
    static void udp_listener_thread(void* pArguments)
    {
        // Get the class instance
        udp_listen *listener = (udp_listen *)pArguments;

        // Open the socket
        boost::asio::io_service io_service;
        boost::asio::ip::udp::socket socket(io_service);
        boost::system::error_code error;
        socket.open(boost::asio::ip::udp::v4(), error);
        if (error)
            return;

		// Allow binding to the same port as another application
		socket.set_option(boost::asio::ip::udp::socket::reuse_address(true));
        
        // Join the multicast group
        socket.set_option(boost::asio::ip::multicast::join_group(boost::asio::ip::address::from_string("239.12.13.14")));

        // Bind to the desired port
        socket.bind(boost::asio::ip::udp::endpoint(boost::asio::ip::address_v4::any(), listener->port_m), error);
		if (error)
			return;

        // Use a 0.1s timeout on the native socket
        fd_set fileDescriptorSet;
        struct timeval timeStruct;
        timeStruct.tv_sec = 0;
        timeStruct.tv_usec = 100000;
        FD_ZERO(&fileDescriptorSet);
        int nativeSocket = socket.native();

        // Keep listening until we're told not to
        while (listener->port_m >= 0) {
            // Wait for message with timeout
            FD_SET(nativeSocket, &fileDescriptorSet);
            select(nativeSocket+1, &fileDescriptorSet, NULL, NULL, &timeStruct);
            if (FD_ISSET(nativeSocket, &fileDescriptorSet)) {
                // Not timeout - read message
                listener->get_lock(); // Grab the buffer lock
                boost::asio::ip::udp::endpoint server;
                listener->messageLength_m = socket.receive_from(boost::asio::buffer(listener->buffer_m, sizeof(listener->buffer_m)), server);
                listener->release_lock(); // Release the lock
                listener->message_event(); // Signal the main thread that a message arrived
            }
        }

        // Close the socket
        socket.close(error);
        return;
    }
};

#ifdef _MATLAB_
void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{   
    if (nlhs == 0 && nrhs == 1) {
        // One input, no outputs - close port
        // Input: handle
        // Destroy the C++ object instance
        destroyObject<udp_listen>(prhs[0]);
        return;
    }
    
    if (nlhs == 1 && nrhs == 2) {
        // Two inputs, one output - Get last heard variable
        // Input: handle, timeout. Output: variable.
        // Convert handle to the C++ object instance
        udp_listen *listener = convertMat2Ptr<udp_listen>(prhs[0]);
        
        // Get the timeout time
        if (!mxIsNumeric(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1)
            mexErrMsgTxt("Timeout should be a scalar");
        double timeout = mxGetScalar(prhs[1]);
        
        // Get the message
        plhs[0] = listener->get_message(timeout);
        return;
    }
    
    if (nlhs == 1 && nrhs == 1) {
        // One input (scalar), one output - open port
        // Input: port num. Output: handle.
        // Check the first input is a port
        if (!mxIsNumeric(prhs[0]) || mxGetNumberOfElements(prhs[0]) != 1)
            mexErrMsgTxt("Input should be a port number");
        // Get the port number
        unsigned short port = (unsigned short)mxGetScalar(prhs[0]);
        // Initialize and return
        plhs[0] = convertPtr2Mat<udp_listen>(new udp_listen(port));
        return;
    }
    
    // Shouldn't get here
    mexErrMsgTxt("Unexpected arguments");
}
#else
#include <boost/scoped_ptr.hpp>
// C-style function to get the last 12 doubles of the message
extern "C" __declspec(dllexport) void get_message(double T_k2b[12])
{
	// Initialize the listener first time
	static boost::scoped_ptr<udp_listen> lh;
	if (!lh.get())
		lh.reset(new udp_listen(17436));

	// Read in the message
	uint8_t buffer[1024];
	int n = lh->get_message(buffer, 1024, 0.0);
	if (n)
		memcpy(T_k2b, &buffer[n-sizeof(double)*12], sizeof(double)*12);
	else
		T_k2b[0] = std::numeric_limits<double>::quiet_NaN();
}
#endif