package com.example.restservice;

import java.io.IOException;
import java.net.InetAddress;
import java.nio.file.Files;
import java.nio.file.Path;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Says which machine answered, on every response, so a client behind a load balancer can
 * tell instances apart (for example, to time when a newly added instance starts serving).
 *
 * <ul>
 *   <li>{@code X-Served-By}: the {@code SERVED_BY} environment variable if set, else the
 *       hostname (in a container, that is the container's).</li>
 *   <li>{@code X-Boot-Id}: the kernel boot id. One per VM, and the same inside a container,
 *       so it tells VMs apart even when hostnames are container ids.</li>
 *   <li>{@code Connection: close}: one request per connection, so a proxy in front cannot
 *       pin all traffic to the instance it first connected to.</li>
 *   <li>{@code Cache-Control: no-store}: never answered from a cache.</li>
 * </ul>
 */
@Component
public class ServedByFilter extends OncePerRequestFilter {

  static final String SERVED_BY = "X-Served-By";
  static final String BOOT_ID = "X-Boot-Id";

  private final String servedBy = servedBy();
  private final String bootId = bootId();

  @Override
  protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
      FilterChain chain) throws ServletException, IOException {
    response.setHeader(SERVED_BY, servedBy);
    if (bootId != null) {
      response.setHeader(BOOT_ID, bootId);
    }
    response.setHeader("Connection", "close");
    response.setHeader("Cache-Control", "no-store");
    chain.doFilter(request, response);
  }

  private static String servedBy() {
    String fromEnv = System.getenv("SERVED_BY");
    if (fromEnv != null && !fromEnv.isBlank()) {
      return fromEnv.strip();
    }
    try {
      return InetAddress.getLocalHost().getHostName();
    } catch (IOException e) {
      return "unknown";
    }
  }

  private static String bootId() {
    try {
      return Files.readString(Path.of("/proc/sys/kernel/random/boot_id")).strip();
    } catch (IOException | RuntimeException e) {
      return null;  // not Linux, or not readable
    }
  }
}
