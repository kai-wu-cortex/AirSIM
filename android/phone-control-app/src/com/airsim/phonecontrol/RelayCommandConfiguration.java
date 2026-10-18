package com.airsim.phonecontrol;

import java.util.Objects;
import java.util.function.Function;
import java.util.function.Supplier;

/** Single authoritative reader: consumers can validate snapshots, never reconfigure from them. */
final class RelayCommandConfiguration<T> {
    record Snapshot<T>(T registration, String scope, long epoch) {}
    private final Supplier<T> reader;
    private final Function<T,String> identity;
    private final RelayCommandRetryState retry;
    private boolean stopped;
    RelayCommandConfiguration(Supplier<T> reader, Function<T,String> identity, RelayCommandRetryState retry) {
        this.reader=reader;this.identity=identity;this.retry=retry;
    }
    synchronized Snapshot<T> snapshot() {
        T value=stopped ? null : reader.get();
        String scope=value==null ? null : identity.apply(value);
        return new Snapshot<>(value,scope,retry.configure(scope));
    }
    synchronized boolean isCurrent(Snapshot<T> candidate) {
        Snapshot<T> current=snapshot();
        return candidate!=null && current.scope()!=null && candidate.epoch()==current.epoch()
                && Objects.equals(candidate.scope(),current.scope());
    }
    synchronized void stop() { stopped=true;retry.configure(null); }
}
