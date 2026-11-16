/* Interrupts from devices: who is to be told when one arrives.
 *
 * The timer's interrupt is the architecture's own business. Every other
 * interrupt so far is a message: a PCI device writes a number to an
 * address that the interrupt controller listens at (MSI and MSI-X, PCI
 * Local Bus Specification 3.0, 6.8). Which address and which number is for
 * the controller to say, and there are three kinds of it on the machines
 * at hand (kernel/arch/<arch>/interrupt.c). What they have in common is
 * here: a table of sources, each with the function that its interrupt
 * calls. A source is handed out once and never given back.
 *
 * A handler runs with interrupts off and does next to nothing: the one
 * there is signals an event, and a thread in Lisp does the rest
 * (kernel/lisp/thread.c). */
#include "kernel.h"

static void (*g_handlers[INTERRUPT_SOURCES])(unsigned source);
static unsigned g_sources; /* how many have been handed out */

int interrupt_message(uint32_t device, void (*handler)(unsigned source), struct interrupt_message *m)
{
    unsigned source = g_sources;

    if (!arch_message_controller)
        return -1;
    if (source == INTERRUPT_SOURCES)
        return -2;
    /* The handler is in place before the controller knows the source, and
     * the source counts as handed out only once the controller does. */
    g_handlers[source] = handler;
    if (!arch_message(device, source, m)) {
        g_handlers[source] = NULL;
        return -2;
    }
    g_sources = source + 1;
    return (int)source;
}

void interrupt_deliver(unsigned source)
{
    if (source < INTERRUPT_SOURCES && g_handlers[source])
        g_handlers[source](source);
    else
        kprintf("an interrupt from the source of messages %u, which nothing asked for\n", source);
}
