#include <stdint.h>

#define BOOST_DATE_TIME_NO_LIB
#define BOOST_REGEX_NO_LIB
#include <boost/asio.hpp>
#include <boost/chrono.hpp>
#include <boost/thread.hpp>

// Class for sending a buffer over a UDP connection

class udp_broadcast {
public:
    // Constructor
    udp_broadcast(int port)
    {
        // Set the port number
        port_m = port;
        // Make sure we have no message to start
        messageLength_m = 0;
        // Create the looping thread
        hThread_m = boost::thread(&(this->udp_broadcast_thread), this);
    }
    // Destructor
    ~udp_broadcast()
    {
        // Signal the thread to end
        port_m = -1;
        message_event();
        // Wait for it to die
        hThread_m.join();
    }
    // Broadcast
    bool broadcast(const void *buf, size_t nbytes, double timeout)
    { 
        // Errror checking and grabbing buffer lock
        if (nbytes > sizeof(buffer_m) || port_m < 0 || !get_lock(timeout))
            return false;
        // Copy data to the internal buffer
        memcpy(buffer_m, buf, nbytes);
        messageLength_m = nbytes;
        // Release the buffer lock
        release_lock();
        // Signal the broadcast thread
        message_event();
        return true;
    }    
    
private:
    // Port number - also used for killing the thread
    volatile int port_m;
    
    // Functions for avoiding simultaneous access to the buffer
    void get_lock() { hMutex_m.lock(); }
    bool get_lock(double timeout) { return hMutex_m.try_lock_for(boost::chrono::milliseconds(int(timeout*1000.0))); }
    void release_lock() { hMutex_m.unlock(); }
    // Functions for efficient waiting for messages
    void message_event() { boost::mutex::scoped_lock lock(hEventMutex_m); hEvent_m.notify_all(); }
    void message_wait() { boost::mutex::scoped_lock lock(hEventMutex_m); hEvent_m.wait(lock); }   
    // Buffer for storing the data in
    uint8_t buffer_m[65507]; // Maximum UDP message size
    size_t messageLength_m;
    
    // Thread variables
    boost::thread hThread_m;
    boost::timed_mutex hMutex_m;
    boost::condition_variable hEvent_m;
    boost::mutex hEventMutex_m;
    
    // This thread loops continuously in the background, broadcasting messages
    static void udp_broadcast_thread(void* pArguments)
    {
        // Get the class instance
        udp_broadcast *broadcaster = (udp_broadcast *)pArguments;

        // Open the socket
        boost::asio::io_service io_service;
        boost::asio::ip::udp::socket socket(io_service);
        boost::system::error_code error;
        socket.open(boost::asio::ip::udp::v4(), error);
        if (error) {
            broadcaster->port_m = -1;
            return;
        }

		// Allow binding to the same port as another application
		socket.set_option(boost::asio::ip::udp::socket::reuse_address(true));
        
        // Only send over network (very slow!) if port > 0.
		int hops = 2; // 2 router hops by default should be enough to reach other listening computers
		if (broadcaster->port_m < 0) {
			broadcaster->port_m = -broadcaster->port_m;
			hops = 0;
		}
        socket.set_option(boost::asio::ip::multicast::hops(hops));
        
        // Set the end points
        boost::asio::ip::udp::endpoint senderEndpoint(boost::asio::ip::address::from_string("239.12.13.14"), broadcaster->port_m);
        
        // Broadcast loop
        // Keep broadcasting until we're told not to
        while (broadcaster->port_m >= 0) {
            // Wait for message with timeout
            broadcaster->message_wait();
            // Check if thread was asked to end
            if (broadcaster->port_m < 0)
                break;
            // Acquire buffer lock
            broadcaster->get_lock();
            if (broadcaster->messageLength_m) {
                // Not timeout - broadcast message
                socket.send_to(boost::asio::buffer(broadcaster->buffer_m, broadcaster->messageLength_m), senderEndpoint);
                broadcaster->messageLength_m = 0;
            }
            broadcaster->release_lock(); // Release the lock
        }
        
        // Close the socket
        socket.close(error);
        broadcaster->port_m = -1;
        return;
    }
};

#ifdef _MATLAB_
#include "mex.h"
#include "class_handle.hpp"
extern "C" mxArray* mxSerialize(const mxArray*);

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    if (nrhs > 1) {        
        // Two inputs - send variable
        // Input 1: handle
        // Input 2: variable
        // Convert handle to the C++ object instance
        udp_broadcast *broadcaster = convertMat2Ptr<udp_broadcast>(prhs[0]);
        
        // Serialize the input
        mxArray *serial = mxSerialize(prhs[1]);
        size_t numel = mxGetNumberOfElements(serial) * mxGetElementSize(serial);
        if (numel > 65507) {
            mxDestroyArray(serial); // Destroy the serialized array
            mexErrMsgTxt("Error: data too large for a single packet");
        }
        
        // Get the timeout time
        double timeout = 0.0; // Default: 0s, i.e. if broadcast in progress, reject this broadcast
        if (nrhs > 2)
            timeout = mxGetScalar(prhs[2]);
        
        // Send the data
        bool success = broadcaster->broadcast(mxGetData(serial), numel, timeout);
        mxDestroyArray(serial); // Destroy the serialized array
        
        // Output if required
        if (nlhs > 0) {
            uint32_t output[2];
            // Get the message size
            output[0] = numel;
            // Indicate if timed out
            output[1] = success;
            // Output the data
            plhs[0] = mxCreateNumericMatrix(1, 2, mxUINT32_CLASS, mxREAL);
            memcpy(mxGetData(plhs[0]), output, sizeof(output));
        }
    } else {
        if (nlhs > 0) {
            // One input, one output - open port
            // Input: port num.
            // Output: handle.
            // Check the first input is a port
            if (!mxIsNumeric(prhs[0]) || mxGetNumberOfElements(prhs[0]) != 1)
                mexErrMsgTxt("Input should be a port number");
            // Get the port number
            int port = (int)mxGetScalar(prhs[0]);
            // Initialize and return
            plhs[0] = convertPtr2Mat<udp_broadcast>(new udp_broadcast(port));
        } else {
            // One input, no outputs - close port
            // Input: handle
            // Destroy the C++ object instance
            destroyObject<udp_broadcast>(prhs[0]);
        }
    }
}
#endif //_MATLAB_