#ifndef SRTTransportShim_h
#define SRTTransportShim_h

#include <stddef.h>
#include <stdint.h>

int rnc_srt_connect(const char *numericHost,
                    uint16_t port,
                    const char *passphrase,
                    int *socketOut,
                    char *errorOut,
                    size_t errorCapacity);
int rnc_srt_send(int socket, const uint8_t *bytes, size_t length);
void rnc_srt_close(int socket);
const char *rnc_srt_last_error(void);

#endif
