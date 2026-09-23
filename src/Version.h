/*
 * Version.h
 *
 *  Created on: 25 Dec 2016
 *      Author: David
 */

#ifndef SRC_VERSION_H_
#define SRC_VERSION_H_

// Debug build identity: VERSION becomes <MAIN_VERSION>.dbg.<API>.<BUILD>, 23 characters at most.
// VM_DEBUG_API is the contract level the Debug Tools plugin checks; when to raise it, and the
// counter rules, are in that plugin's README. Keep these lines clear of MAIN_VERSION below, which
// is the only line visionminer-3.5 ever edits, so merges from it stay conflict-free.
#define VM_DEBUG_API	"1"
#define VM_DEBUG_BUILD	"1"
#define VM_DEBUG_SUFFIX	".dbg." VM_DEBUG_API "." VM_DEBUG_BUILD

#ifndef VERSION
// Note: the complete VERSION string must be in standard version number format and must not contain spaces! This is so that DWC can parse it.
# define MAIN_VERSION	"3.5.4-vm.1+1"
# ifdef USE_CAN0
#  define VERSION_SUFFIX	"(CAN0)"
# else
#  define VERSION_SUFFIX	""
# endif
# define VERSION MAIN_VERSION VM_DEBUG_SUFFIX VERSION_SUFFIX
#endif

extern const char *const DATE;
extern const char *const TIME_SUFFIX;

#define AUTHORS "reprappro, dc42, chrishamm, t3p3, dnewman, printm3d"

#endif /* SRC_VERSION_H_ */
