#include "SRTTransportShim.h"

#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <srt/srt.h>

static int startupResult = -1;
static pthread_once_t startupToken = PTHREAD_ONCE_INIT;

static void start_srt_once(void) {
    startupResult = srt_startup();
}

static int ensure_srt_started(void) {
    pthread_once(&startupToken, start_srt_once);
    return startupResult;
}

int rnc_srt_connect(const char *numericHost,
                    uint16_t port,
                    const char *passphrase,
                    int *socketOut,
                    char *errorOut,
                    size_t errorCapacity) {
    if (numericHost == NULL || passphrase == NULL || socketOut == NULL
        || errorOut == NULL || errorCapacity == 0) {
        return -1;
    }

    errorOut[0] = '\0';
    *socketOut = SRT_INVALID_SOCK;
    const size_t passphraseLength = strlen(passphrase);
    if (passphraseLength < 10 || passphraseLength > 79) {
        snprintf(errorOut, errorCapacity, "The SRT passphrase must contain 10 to 79 characters.");
        return -1;
    }

    if (ensure_srt_started() == SRT_ERROR) {
        snprintf(errorOut, errorCapacity, "libsrt startup failed: %s", srt_getlasterror_str());
        return -1;
    }

    char portString[6];
    snprintf(portString, sizeof(portString), "%u", (unsigned int)port);

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    hints.ai_flags = AI_NUMERICHOST;

    struct addrinfo *addresses = NULL;
    int resolveResult = getaddrinfo(numericHost, portString, &hints, &addresses);
    if (resolveResult != 0) {
        snprintf(errorOut, errorCapacity, "Unable to parse resolved IP address: %s",
                 gai_strerror(resolveResult));
        return -1;
    }

    SRTSOCKET socket = srt_create_socket();
    if (socket == SRT_INVALID_SOCK) {
        snprintf(errorOut, errorCapacity, "Unable to create SRT socket: %s",
                 srt_getlasterror_str());
        freeaddrinfo(addresses);
        return -1;
    }

    SRT_TRANSTYPE transportType = SRTT_LIVE;
    int messageApi = 1;
    int sendTimeoutMilliseconds = 1000;
    int optionResult = srt_setsockopt(socket, 0, SRTO_TRANSTYPE,
                                      &transportType, sizeof(transportType));
    if (optionResult == SRT_ERROR) {
        snprintf(errorOut, errorCapacity, "Unable to configure SRT live mode: %s",
                 srt_getlasterror_str());
        srt_close(socket);
        freeaddrinfo(addresses);
        return -1;
    }

    optionResult = srt_setsockopt(socket, 0, SRTO_MESSAGEAPI,
                                  &messageApi, sizeof(messageApi));
    if (optionResult == SRT_ERROR) {
        snprintf(errorOut, errorCapacity, "Unable to configure SRT message mode: %s",
                 srt_getlasterror_str());
        srt_close(socket);
        freeaddrinfo(addresses);
        return -1;
    }

    optionResult = srt_setsockopt(socket, 0, SRTO_SNDTIMEO,
                                  &sendTimeoutMilliseconds, sizeof(sendTimeoutMilliseconds));
    if (optionResult == SRT_ERROR) {
        snprintf(errorOut, errorCapacity, "Unable to configure SRT send timeout: %s",
                 srt_getlasterror_str());
        srt_close(socket);
        freeaddrinfo(addresses);
        return -1;
    }

    int keyLength = 16;
    if (srt_setsockopt(socket, 0, SRTO_PBKEYLEN,
                       &keyLength, sizeof(keyLength)) == SRT_ERROR
        || srt_setsockopt(socket, 0, SRTO_PASSPHRASE,
                          passphrase, (int)passphraseLength) == SRT_ERROR) {
        snprintf(errorOut, errorCapacity, "Unable to configure SRT encryption: %s",
                 srt_getlasterror_str());
        srt_close(socket);
        freeaddrinfo(addresses);
        return -1;
    }

    int connected = 0;
    for (struct addrinfo *address = addresses; address != NULL; address = address->ai_next) {
        if (srt_connect(socket, address->ai_addr, (int)address->ai_addrlen) != SRT_ERROR) {
            connected = 1;
            break;
        }
    }
    freeaddrinfo(addresses);

    if (!connected) {
        snprintf(errorOut, errorCapacity, "SRT connection failed: %s",
                 srt_getlasterror_str());
        srt_close(socket);
        return -1;
    }

    *socketOut = (int)socket;
    return 0;
}

int rnc_srt_send(int socket, const uint8_t *bytes, size_t length) {
    if (socket == SRT_INVALID_SOCK || bytes == NULL || length == 0 || length > INT32_MAX) {
        return SRT_ERROR;
    }
    return srt_sendmsg((SRTSOCKET)socket, (const char *)bytes, (int)length, -1, 1);
}

void rnc_srt_close(int socket) {
    if (socket != SRT_INVALID_SOCK) {
        srt_close((SRTSOCKET)socket);
    }
}

const char *rnc_srt_last_error(void) {
    return srt_getlasterror_str();
}
