package com.example.restservice;

import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.resttestclient.autoconfigure.AutoConfigureRestTestClient;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.client.RestTestClient;

// A real server (random port), so servlet filters and connection headers are what a client sees.
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureRestTestClient
public class GreetingControllerTests {

  @Autowired
  private RestTestClient restTestClient;

  @Test
  public void noParamGreetingShouldReturnDefaultMessage() throws Exception {

    this.restTestClient.get().uri("/greeting")
        .exchange()
        .expectStatus().isOk()
        .expectBody()
        .jsonPath("$.content").isEqualTo("Hello, World!");
  }

  @Test
  public void paramGreetingShouldReturnTailoredMessage() throws Exception {

    this.restTestClient.get()
        .uri(uri -> uri.path("/greeting").queryParam("name", "Spring Community").build())
        .exchange()
        .expectStatus().isOk()
        .expectBody()
        .jsonPath("$.content").isEqualTo("Hello, Spring Community!");
  }

  @Test
  public void everyResponseSaysWhoServedItAndClosesTheConnection() throws Exception {

    this.restTestClient.get().uri("/greeting")
        .exchange()
        .expectStatus().isOk()
        .expectHeader().exists(ServedByFilter.SERVED_BY)
        .expectHeader().valueEquals("Connection", "close")
        .expectHeader().valueEquals("Cache-Control", "no-store");
  }

}
