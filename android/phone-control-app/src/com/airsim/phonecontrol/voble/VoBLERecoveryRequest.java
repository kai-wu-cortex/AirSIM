package com.airsim.phonecontrol.voble;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.BooleanSupplier;
import java.util.function.Predicate;

/** Coalesce foreground recovery requests without restarting a live service or media. */
public final class VoBLERecoveryRequest {
    private final AtomicBoolean pending = new AtomicBoolean();
    public void request(Predicate<Runnable> post, BooleanSupplier alive, Runnable recover) {
        if (!pending.compareAndSet(false, true)) return;
        try {
            if (!post.test(() -> {
                pending.set(false);
                if (alive.getAsBoolean()) recover.run();
            })) pending.set(false);
        } catch (RuntimeException error) { pending.set(false); throw error; }
    }
}
