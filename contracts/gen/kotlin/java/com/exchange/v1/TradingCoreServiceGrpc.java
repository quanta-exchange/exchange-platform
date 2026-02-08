package com.exchange.v1;

import static io.grpc.MethodDescriptor.generateFullMethodName;

/**
 */
@io.grpc.stub.annotations.GrpcGenerated
public final class TradingCoreServiceGrpc {

  private TradingCoreServiceGrpc() {}

  public static final java.lang.String SERVICE_NAME = "exchange.v1.TradingCoreService";

  // Static method descriptors that strictly reflect the proto.
  private static volatile io.grpc.MethodDescriptor<com.exchange.v1.PlaceOrderRequest,
      com.exchange.v1.PlaceOrderResponse> getPlaceOrderMethod;

  @io.grpc.stub.annotations.RpcMethod(
      fullMethodName = SERVICE_NAME + '/' + "PlaceOrder",
      requestType = com.exchange.v1.PlaceOrderRequest.class,
      responseType = com.exchange.v1.PlaceOrderResponse.class,
      methodType = io.grpc.MethodDescriptor.MethodType.UNARY)
  public static io.grpc.MethodDescriptor<com.exchange.v1.PlaceOrderRequest,
      com.exchange.v1.PlaceOrderResponse> getPlaceOrderMethod() {
    io.grpc.MethodDescriptor<com.exchange.v1.PlaceOrderRequest, com.exchange.v1.PlaceOrderResponse> getPlaceOrderMethod;
    if ((getPlaceOrderMethod = TradingCoreServiceGrpc.getPlaceOrderMethod) == null) {
      synchronized (TradingCoreServiceGrpc.class) {
        if ((getPlaceOrderMethod = TradingCoreServiceGrpc.getPlaceOrderMethod) == null) {
          TradingCoreServiceGrpc.getPlaceOrderMethod = getPlaceOrderMethod =
              io.grpc.MethodDescriptor.<com.exchange.v1.PlaceOrderRequest, com.exchange.v1.PlaceOrderResponse>newBuilder()
              .setType(io.grpc.MethodDescriptor.MethodType.UNARY)
              .setFullMethodName(generateFullMethodName(SERVICE_NAME, "PlaceOrder"))
              .setSampledToLocalTracing(true)
              .setRequestMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.PlaceOrderRequest.getDefaultInstance()))
              .setResponseMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.PlaceOrderResponse.getDefaultInstance()))
              .setSchemaDescriptor(new TradingCoreServiceMethodDescriptorSupplier("PlaceOrder"))
              .build();
        }
      }
    }
    return getPlaceOrderMethod;
  }

  private static volatile io.grpc.MethodDescriptor<com.exchange.v1.CancelOrderRequest,
      com.exchange.v1.CancelOrderResponse> getCancelOrderMethod;

  @io.grpc.stub.annotations.RpcMethod(
      fullMethodName = SERVICE_NAME + '/' + "CancelOrder",
      requestType = com.exchange.v1.CancelOrderRequest.class,
      responseType = com.exchange.v1.CancelOrderResponse.class,
      methodType = io.grpc.MethodDescriptor.MethodType.UNARY)
  public static io.grpc.MethodDescriptor<com.exchange.v1.CancelOrderRequest,
      com.exchange.v1.CancelOrderResponse> getCancelOrderMethod() {
    io.grpc.MethodDescriptor<com.exchange.v1.CancelOrderRequest, com.exchange.v1.CancelOrderResponse> getCancelOrderMethod;
    if ((getCancelOrderMethod = TradingCoreServiceGrpc.getCancelOrderMethod) == null) {
      synchronized (TradingCoreServiceGrpc.class) {
        if ((getCancelOrderMethod = TradingCoreServiceGrpc.getCancelOrderMethod) == null) {
          TradingCoreServiceGrpc.getCancelOrderMethod = getCancelOrderMethod =
              io.grpc.MethodDescriptor.<com.exchange.v1.CancelOrderRequest, com.exchange.v1.CancelOrderResponse>newBuilder()
              .setType(io.grpc.MethodDescriptor.MethodType.UNARY)
              .setFullMethodName(generateFullMethodName(SERVICE_NAME, "CancelOrder"))
              .setSampledToLocalTracing(true)
              .setRequestMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.CancelOrderRequest.getDefaultInstance()))
              .setResponseMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.CancelOrderResponse.getDefaultInstance()))
              .setSchemaDescriptor(new TradingCoreServiceMethodDescriptorSupplier("CancelOrder"))
              .build();
        }
      }
    }
    return getCancelOrderMethod;
  }

  private static volatile io.grpc.MethodDescriptor<com.exchange.v1.SetSymbolModeRequest,
      com.exchange.v1.SetSymbolModeResponse> getSetSymbolModeMethod;

  @io.grpc.stub.annotations.RpcMethod(
      fullMethodName = SERVICE_NAME + '/' + "SetSymbolMode",
      requestType = com.exchange.v1.SetSymbolModeRequest.class,
      responseType = com.exchange.v1.SetSymbolModeResponse.class,
      methodType = io.grpc.MethodDescriptor.MethodType.UNARY)
  public static io.grpc.MethodDescriptor<com.exchange.v1.SetSymbolModeRequest,
      com.exchange.v1.SetSymbolModeResponse> getSetSymbolModeMethod() {
    io.grpc.MethodDescriptor<com.exchange.v1.SetSymbolModeRequest, com.exchange.v1.SetSymbolModeResponse> getSetSymbolModeMethod;
    if ((getSetSymbolModeMethod = TradingCoreServiceGrpc.getSetSymbolModeMethod) == null) {
      synchronized (TradingCoreServiceGrpc.class) {
        if ((getSetSymbolModeMethod = TradingCoreServiceGrpc.getSetSymbolModeMethod) == null) {
          TradingCoreServiceGrpc.getSetSymbolModeMethod = getSetSymbolModeMethod =
              io.grpc.MethodDescriptor.<com.exchange.v1.SetSymbolModeRequest, com.exchange.v1.SetSymbolModeResponse>newBuilder()
              .setType(io.grpc.MethodDescriptor.MethodType.UNARY)
              .setFullMethodName(generateFullMethodName(SERVICE_NAME, "SetSymbolMode"))
              .setSampledToLocalTracing(true)
              .setRequestMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.SetSymbolModeRequest.getDefaultInstance()))
              .setResponseMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.SetSymbolModeResponse.getDefaultInstance()))
              .setSchemaDescriptor(new TradingCoreServiceMethodDescriptorSupplier("SetSymbolMode"))
              .build();
        }
      }
    }
    return getSetSymbolModeMethod;
  }

  private static volatile io.grpc.MethodDescriptor<com.exchange.v1.CancelAllRequest,
      com.exchange.v1.CancelAllResponse> getCancelAllMethod;

  @io.grpc.stub.annotations.RpcMethod(
      fullMethodName = SERVICE_NAME + '/' + "CancelAll",
      requestType = com.exchange.v1.CancelAllRequest.class,
      responseType = com.exchange.v1.CancelAllResponse.class,
      methodType = io.grpc.MethodDescriptor.MethodType.UNARY)
  public static io.grpc.MethodDescriptor<com.exchange.v1.CancelAllRequest,
      com.exchange.v1.CancelAllResponse> getCancelAllMethod() {
    io.grpc.MethodDescriptor<com.exchange.v1.CancelAllRequest, com.exchange.v1.CancelAllResponse> getCancelAllMethod;
    if ((getCancelAllMethod = TradingCoreServiceGrpc.getCancelAllMethod) == null) {
      synchronized (TradingCoreServiceGrpc.class) {
        if ((getCancelAllMethod = TradingCoreServiceGrpc.getCancelAllMethod) == null) {
          TradingCoreServiceGrpc.getCancelAllMethod = getCancelAllMethod =
              io.grpc.MethodDescriptor.<com.exchange.v1.CancelAllRequest, com.exchange.v1.CancelAllResponse>newBuilder()
              .setType(io.grpc.MethodDescriptor.MethodType.UNARY)
              .setFullMethodName(generateFullMethodName(SERVICE_NAME, "CancelAll"))
              .setSampledToLocalTracing(true)
              .setRequestMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.CancelAllRequest.getDefaultInstance()))
              .setResponseMarshaller(io.grpc.protobuf.ProtoUtils.marshaller(
                  com.exchange.v1.CancelAllResponse.getDefaultInstance()))
              .setSchemaDescriptor(new TradingCoreServiceMethodDescriptorSupplier("CancelAll"))
              .build();
        }
      }
    }
    return getCancelAllMethod;
  }

  /**
   * Creates a new async stub that supports all call types for the service
   */
  public static TradingCoreServiceStub newStub(io.grpc.Channel channel) {
    io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceStub> factory =
      new io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceStub>() {
        @java.lang.Override
        public TradingCoreServiceStub newStub(io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
          return new TradingCoreServiceStub(channel, callOptions);
        }
      };
    return TradingCoreServiceStub.newStub(factory, channel);
  }

  /**
   * Creates a new blocking-style stub that supports all types of calls on the service
   */
  public static TradingCoreServiceBlockingV2Stub newBlockingV2Stub(
      io.grpc.Channel channel) {
    io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceBlockingV2Stub> factory =
      new io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceBlockingV2Stub>() {
        @java.lang.Override
        public TradingCoreServiceBlockingV2Stub newStub(io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
          return new TradingCoreServiceBlockingV2Stub(channel, callOptions);
        }
      };
    return TradingCoreServiceBlockingV2Stub.newStub(factory, channel);
  }

  /**
   * Creates a new blocking-style stub that supports unary and streaming output calls on the service
   */
  public static TradingCoreServiceBlockingStub newBlockingStub(
      io.grpc.Channel channel) {
    io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceBlockingStub> factory =
      new io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceBlockingStub>() {
        @java.lang.Override
        public TradingCoreServiceBlockingStub newStub(io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
          return new TradingCoreServiceBlockingStub(channel, callOptions);
        }
      };
    return TradingCoreServiceBlockingStub.newStub(factory, channel);
  }

  /**
   * Creates a new ListenableFuture-style stub that supports unary calls on the service
   */
  public static TradingCoreServiceFutureStub newFutureStub(
      io.grpc.Channel channel) {
    io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceFutureStub> factory =
      new io.grpc.stub.AbstractStub.StubFactory<TradingCoreServiceFutureStub>() {
        @java.lang.Override
        public TradingCoreServiceFutureStub newStub(io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
          return new TradingCoreServiceFutureStub(channel, callOptions);
        }
      };
    return TradingCoreServiceFutureStub.newStub(factory, channel);
  }

  /**
   */
  public interface AsyncService {

    /**
     */
    default void placeOrder(com.exchange.v1.PlaceOrderRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.PlaceOrderResponse> responseObserver) {
      io.grpc.stub.ServerCalls.asyncUnimplementedUnaryCall(getPlaceOrderMethod(), responseObserver);
    }

    /**
     */
    default void cancelOrder(com.exchange.v1.CancelOrderRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.CancelOrderResponse> responseObserver) {
      io.grpc.stub.ServerCalls.asyncUnimplementedUnaryCall(getCancelOrderMethod(), responseObserver);
    }

    /**
     */
    default void setSymbolMode(com.exchange.v1.SetSymbolModeRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.SetSymbolModeResponse> responseObserver) {
      io.grpc.stub.ServerCalls.asyncUnimplementedUnaryCall(getSetSymbolModeMethod(), responseObserver);
    }

    /**
     */
    default void cancelAll(com.exchange.v1.CancelAllRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.CancelAllResponse> responseObserver) {
      io.grpc.stub.ServerCalls.asyncUnimplementedUnaryCall(getCancelAllMethod(), responseObserver);
    }
  }

  /**
   * Base class for the server implementation of the service TradingCoreService.
   */
  public static abstract class TradingCoreServiceImplBase
      implements io.grpc.BindableService, AsyncService {

    @java.lang.Override public final io.grpc.ServerServiceDefinition bindService() {
      return TradingCoreServiceGrpc.bindService(this);
    }
  }

  /**
   * A stub to allow clients to do asynchronous rpc calls to service TradingCoreService.
   */
  public static final class TradingCoreServiceStub
      extends io.grpc.stub.AbstractAsyncStub<TradingCoreServiceStub> {
    private TradingCoreServiceStub(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      super(channel, callOptions);
    }

    @java.lang.Override
    protected TradingCoreServiceStub build(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      return new TradingCoreServiceStub(channel, callOptions);
    }

    /**
     */
    public void placeOrder(com.exchange.v1.PlaceOrderRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.PlaceOrderResponse> responseObserver) {
      io.grpc.stub.ClientCalls.asyncUnaryCall(
          getChannel().newCall(getPlaceOrderMethod(), getCallOptions()), request, responseObserver);
    }

    /**
     */
    public void cancelOrder(com.exchange.v1.CancelOrderRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.CancelOrderResponse> responseObserver) {
      io.grpc.stub.ClientCalls.asyncUnaryCall(
          getChannel().newCall(getCancelOrderMethod(), getCallOptions()), request, responseObserver);
    }

    /**
     */
    public void setSymbolMode(com.exchange.v1.SetSymbolModeRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.SetSymbolModeResponse> responseObserver) {
      io.grpc.stub.ClientCalls.asyncUnaryCall(
          getChannel().newCall(getSetSymbolModeMethod(), getCallOptions()), request, responseObserver);
    }

    /**
     */
    public void cancelAll(com.exchange.v1.CancelAllRequest request,
        io.grpc.stub.StreamObserver<com.exchange.v1.CancelAllResponse> responseObserver) {
      io.grpc.stub.ClientCalls.asyncUnaryCall(
          getChannel().newCall(getCancelAllMethod(), getCallOptions()), request, responseObserver);
    }
  }

  /**
   * A stub to allow clients to do synchronous rpc calls to service TradingCoreService.
   */
  public static final class TradingCoreServiceBlockingV2Stub
      extends io.grpc.stub.AbstractBlockingStub<TradingCoreServiceBlockingV2Stub> {
    private TradingCoreServiceBlockingV2Stub(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      super(channel, callOptions);
    }

    @java.lang.Override
    protected TradingCoreServiceBlockingV2Stub build(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      return new TradingCoreServiceBlockingV2Stub(channel, callOptions);
    }

    /**
     */
    public com.exchange.v1.PlaceOrderResponse placeOrder(com.exchange.v1.PlaceOrderRequest request) throws io.grpc.StatusException {
      return io.grpc.stub.ClientCalls.blockingV2UnaryCall(
          getChannel(), getPlaceOrderMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.CancelOrderResponse cancelOrder(com.exchange.v1.CancelOrderRequest request) throws io.grpc.StatusException {
      return io.grpc.stub.ClientCalls.blockingV2UnaryCall(
          getChannel(), getCancelOrderMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.SetSymbolModeResponse setSymbolMode(com.exchange.v1.SetSymbolModeRequest request) throws io.grpc.StatusException {
      return io.grpc.stub.ClientCalls.blockingV2UnaryCall(
          getChannel(), getSetSymbolModeMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.CancelAllResponse cancelAll(com.exchange.v1.CancelAllRequest request) throws io.grpc.StatusException {
      return io.grpc.stub.ClientCalls.blockingV2UnaryCall(
          getChannel(), getCancelAllMethod(), getCallOptions(), request);
    }
  }

  /**
   * A stub to allow clients to do limited synchronous rpc calls to service TradingCoreService.
   */
  public static final class TradingCoreServiceBlockingStub
      extends io.grpc.stub.AbstractBlockingStub<TradingCoreServiceBlockingStub> {
    private TradingCoreServiceBlockingStub(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      super(channel, callOptions);
    }

    @java.lang.Override
    protected TradingCoreServiceBlockingStub build(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      return new TradingCoreServiceBlockingStub(channel, callOptions);
    }

    /**
     */
    public com.exchange.v1.PlaceOrderResponse placeOrder(com.exchange.v1.PlaceOrderRequest request) {
      return io.grpc.stub.ClientCalls.blockingUnaryCall(
          getChannel(), getPlaceOrderMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.CancelOrderResponse cancelOrder(com.exchange.v1.CancelOrderRequest request) {
      return io.grpc.stub.ClientCalls.blockingUnaryCall(
          getChannel(), getCancelOrderMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.SetSymbolModeResponse setSymbolMode(com.exchange.v1.SetSymbolModeRequest request) {
      return io.grpc.stub.ClientCalls.blockingUnaryCall(
          getChannel(), getSetSymbolModeMethod(), getCallOptions(), request);
    }

    /**
     */
    public com.exchange.v1.CancelAllResponse cancelAll(com.exchange.v1.CancelAllRequest request) {
      return io.grpc.stub.ClientCalls.blockingUnaryCall(
          getChannel(), getCancelAllMethod(), getCallOptions(), request);
    }
  }

  /**
   * A stub to allow clients to do ListenableFuture-style rpc calls to service TradingCoreService.
   */
  public static final class TradingCoreServiceFutureStub
      extends io.grpc.stub.AbstractFutureStub<TradingCoreServiceFutureStub> {
    private TradingCoreServiceFutureStub(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      super(channel, callOptions);
    }

    @java.lang.Override
    protected TradingCoreServiceFutureStub build(
        io.grpc.Channel channel, io.grpc.CallOptions callOptions) {
      return new TradingCoreServiceFutureStub(channel, callOptions);
    }

    /**
     */
    public com.google.common.util.concurrent.ListenableFuture<com.exchange.v1.PlaceOrderResponse> placeOrder(
        com.exchange.v1.PlaceOrderRequest request) {
      return io.grpc.stub.ClientCalls.futureUnaryCall(
          getChannel().newCall(getPlaceOrderMethod(), getCallOptions()), request);
    }

    /**
     */
    public com.google.common.util.concurrent.ListenableFuture<com.exchange.v1.CancelOrderResponse> cancelOrder(
        com.exchange.v1.CancelOrderRequest request) {
      return io.grpc.stub.ClientCalls.futureUnaryCall(
          getChannel().newCall(getCancelOrderMethod(), getCallOptions()), request);
    }

    /**
     */
    public com.google.common.util.concurrent.ListenableFuture<com.exchange.v1.SetSymbolModeResponse> setSymbolMode(
        com.exchange.v1.SetSymbolModeRequest request) {
      return io.grpc.stub.ClientCalls.futureUnaryCall(
          getChannel().newCall(getSetSymbolModeMethod(), getCallOptions()), request);
    }

    /**
     */
    public com.google.common.util.concurrent.ListenableFuture<com.exchange.v1.CancelAllResponse> cancelAll(
        com.exchange.v1.CancelAllRequest request) {
      return io.grpc.stub.ClientCalls.futureUnaryCall(
          getChannel().newCall(getCancelAllMethod(), getCallOptions()), request);
    }
  }

  private static final int METHODID_PLACE_ORDER = 0;
  private static final int METHODID_CANCEL_ORDER = 1;
  private static final int METHODID_SET_SYMBOL_MODE = 2;
  private static final int METHODID_CANCEL_ALL = 3;

  private static final class MethodHandlers<Req, Resp> implements
      io.grpc.stub.ServerCalls.UnaryMethod<Req, Resp>,
      io.grpc.stub.ServerCalls.ServerStreamingMethod<Req, Resp>,
      io.grpc.stub.ServerCalls.ClientStreamingMethod<Req, Resp>,
      io.grpc.stub.ServerCalls.BidiStreamingMethod<Req, Resp> {
    private final AsyncService serviceImpl;
    private final int methodId;

    MethodHandlers(AsyncService serviceImpl, int methodId) {
      this.serviceImpl = serviceImpl;
      this.methodId = methodId;
    }

    @java.lang.Override
    @java.lang.SuppressWarnings("unchecked")
    public void invoke(Req request, io.grpc.stub.StreamObserver<Resp> responseObserver) {
      switch (methodId) {
        case METHODID_PLACE_ORDER:
          serviceImpl.placeOrder((com.exchange.v1.PlaceOrderRequest) request,
              (io.grpc.stub.StreamObserver<com.exchange.v1.PlaceOrderResponse>) responseObserver);
          break;
        case METHODID_CANCEL_ORDER:
          serviceImpl.cancelOrder((com.exchange.v1.CancelOrderRequest) request,
              (io.grpc.stub.StreamObserver<com.exchange.v1.CancelOrderResponse>) responseObserver);
          break;
        case METHODID_SET_SYMBOL_MODE:
          serviceImpl.setSymbolMode((com.exchange.v1.SetSymbolModeRequest) request,
              (io.grpc.stub.StreamObserver<com.exchange.v1.SetSymbolModeResponse>) responseObserver);
          break;
        case METHODID_CANCEL_ALL:
          serviceImpl.cancelAll((com.exchange.v1.CancelAllRequest) request,
              (io.grpc.stub.StreamObserver<com.exchange.v1.CancelAllResponse>) responseObserver);
          break;
        default:
          throw new AssertionError();
      }
    }

    @java.lang.Override
    @java.lang.SuppressWarnings("unchecked")
    public io.grpc.stub.StreamObserver<Req> invoke(
        io.grpc.stub.StreamObserver<Resp> responseObserver) {
      switch (methodId) {
        default:
          throw new AssertionError();
      }
    }
  }

  public static final io.grpc.ServerServiceDefinition bindService(AsyncService service) {
    return io.grpc.ServerServiceDefinition.builder(getServiceDescriptor())
        .addMethod(
          getPlaceOrderMethod(),
          io.grpc.stub.ServerCalls.asyncUnaryCall(
            new MethodHandlers<
              com.exchange.v1.PlaceOrderRequest,
              com.exchange.v1.PlaceOrderResponse>(
                service, METHODID_PLACE_ORDER)))
        .addMethod(
          getCancelOrderMethod(),
          io.grpc.stub.ServerCalls.asyncUnaryCall(
            new MethodHandlers<
              com.exchange.v1.CancelOrderRequest,
              com.exchange.v1.CancelOrderResponse>(
                service, METHODID_CANCEL_ORDER)))
        .addMethod(
          getSetSymbolModeMethod(),
          io.grpc.stub.ServerCalls.asyncUnaryCall(
            new MethodHandlers<
              com.exchange.v1.SetSymbolModeRequest,
              com.exchange.v1.SetSymbolModeResponse>(
                service, METHODID_SET_SYMBOL_MODE)))
        .addMethod(
          getCancelAllMethod(),
          io.grpc.stub.ServerCalls.asyncUnaryCall(
            new MethodHandlers<
              com.exchange.v1.CancelAllRequest,
              com.exchange.v1.CancelAllResponse>(
                service, METHODID_CANCEL_ALL)))
        .build();
  }

  private static abstract class TradingCoreServiceBaseDescriptorSupplier
      implements io.grpc.protobuf.ProtoFileDescriptorSupplier, io.grpc.protobuf.ProtoServiceDescriptorSupplier {
    TradingCoreServiceBaseDescriptorSupplier() {}

    @java.lang.Override
    public com.google.protobuf.Descriptors.FileDescriptor getFileDescriptor() {
      return com.exchange.v1.TradingProto.getDescriptor();
    }

    @java.lang.Override
    public com.google.protobuf.Descriptors.ServiceDescriptor getServiceDescriptor() {
      return getFileDescriptor().findServiceByName("TradingCoreService");
    }
  }

  private static final class TradingCoreServiceFileDescriptorSupplier
      extends TradingCoreServiceBaseDescriptorSupplier {
    TradingCoreServiceFileDescriptorSupplier() {}
  }

  private static final class TradingCoreServiceMethodDescriptorSupplier
      extends TradingCoreServiceBaseDescriptorSupplier
      implements io.grpc.protobuf.ProtoMethodDescriptorSupplier {
    private final java.lang.String methodName;

    TradingCoreServiceMethodDescriptorSupplier(java.lang.String methodName) {
      this.methodName = methodName;
    }

    @java.lang.Override
    public com.google.protobuf.Descriptors.MethodDescriptor getMethodDescriptor() {
      return getServiceDescriptor().findMethodByName(methodName);
    }
  }

  private static volatile io.grpc.ServiceDescriptor serviceDescriptor;

  public static io.grpc.ServiceDescriptor getServiceDescriptor() {
    io.grpc.ServiceDescriptor result = serviceDescriptor;
    if (result == null) {
      synchronized (TradingCoreServiceGrpc.class) {
        result = serviceDescriptor;
        if (result == null) {
          serviceDescriptor = result = io.grpc.ServiceDescriptor.newBuilder(SERVICE_NAME)
              .setSchemaDescriptor(new TradingCoreServiceFileDescriptorSupplier())
              .addMethod(getPlaceOrderMethod())
              .addMethod(getCancelOrderMethod())
              .addMethod(getSetSymbolModeMethod())
              .addMethod(getCancelAllMethod())
              .build();
        }
      }
    }
    return result;
  }
}
