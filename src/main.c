/*
 * main.c - DownlinkScope command-line entry point.
 *
 * Current state (v0.1.0): project skeleton. The capture and analysis
 * functions come in the next milestones.
 */
#include "dls/version.h"

#include <pcap/pcap.h>
#include <stdio.h>
#include <string.h>

static void print_usage(FILE *out)
{
    fprintf(out, "Usage: downlinkscope [OPTION]\n"
                 "Passive measurement of LoRaWAN downlink losses on the\n"
                 "Semtech UDP link between a gateway and a network server.\n"
                 "\n"
                 "  -h, --help     show this help and exit\n"
                 "  -V, --version  show the version and exit\n");
}

int main(int argc, char **argv)
{
    if (argc == 2 && (strcmp(argv[1], "-V") == 0 || strcmp(argv[1], "--version") == 0)) {
        printf("downlinkscope %s (%s)\n", DLS_VERSION, pcap_lib_version());
        return 0;
    }
    if (argc == 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        print_usage(stdout);
        return 0;
    }
    print_usage(stderr);
    return 2;
}
