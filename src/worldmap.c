/* The world map (CWmRide): no more snapping onto the routes between the worlds.

   The rider's move (1404b83b0, from the ride's update 1404ba520) puts the rider's sphere (+0x600) at the new
   position and asks 1404b74a0 - twice, at 4b8549 and 4b8647 (the second time for a position a little higher) -
   whether it touches one of the map's route volumes: the map collision objects of the route type (a.bcd, listed at
   +0x200, 0x20 each, count +0x91c by 1404b7540).  A touched route sets +0x6a0 = 1, the route (+0x6a4) and its
   segment (+0x6a8), and the rest of the move then follows that route (4b86d3..).  Nothing else of the move comes
   from 4b74a0 (a hit that is not a route changes nothing), so with both calls answering "no route" the rider
   flies freely; landing at a world is the landmarks' own test (WmLandmark, 1404b59b0 / 1404b5890) and stays. */
#include "mod.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern char g_ini[MAX_PATH + 32];
extern int g_debug;

#define FN_ROUTE    0x4b74a0u
static const u32 ROUTE_CALLS[2] = { 0x4b8549, 0x4b8647 };
static int c_free = 1;          /* [WorldMap] FreeFlight */

static int MSABI no_route(u8 *ride) { (void)ride; return 0; }

static int call_ok(u32 rva, u32 target) {
    u8 *p = g_base + rva; s32 d; memcpy(&d, p + 1, 4);
    return p[0] == 0xE8 && (u32)(rva + 5 + d) == target;
}
int worldmap_check(void) {
    char b[32];
    GetPrivateProfileStringA("WorldMap", "FreeFlight", "1", b, sizeof b, g_ini); c_free = atoi(b);
    if (!c_free) return 1;
    for (int i = 0; i < 2; i++) if (!call_ok(ROUTE_CALLS[i], FN_ROUTE)) { LOG("world map: route site %x does not match", ROUTE_CALLS[i]); return 0; }
    return 1;
}
void worldmap_apply(void) {
    if (!c_free) return;
    for (int i = 0; i < 2; i++) hook_call(ROUTE_CALLS[i], FN_ROUTE, no_route, "world map: routes");
    LOG("world map: free flight (no snapping onto routes)");
}
