let kernel = {|
extern "C" __global__ void saxpy(float a, float *x, float *y, float *out, size_t n) {
  size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < n) {
    out[tid] = a * x[tid] + y[tid];
  }
}
|}

let%expect_test "SAXPY compilation" =
  let prog = Cudajit.compile_to_ptx ~cu_src:kernel ~name:"saxpy" ~options:["--use_fast_math"] ~with_debug:true in
  (match prog.log with None -> () | Some log -> Format.printf "\nCUDA Compile log: %s\n%!" log);
  [%expect{| CUDA Compile log: |} ];
  Format.printf "PTX: %s\n%!" @@ Cudajit.string_from_ptx prog;
  [%expect{|
    PTX: //
    // Generated by NVIDIA NVVM Compiler
    //
    // Compiler Build ID: CL-30672275
    // Cuda compilation tools, release 11.5, V11.5.119
    // Based on NVVM 7.0.1
    //

    .version 7.5
    .target sm_52
    .address_size 64

    	// .globl	saxpy

    .visible .entry saxpy(
    	.param .f32 saxpy_param_0,
    	.param .u64 saxpy_param_1,
    	.param .u64 saxpy_param_2,
    	.param .u64 saxpy_param_3,
    	.param .u64 saxpy_param_4
    )
    {
    	.reg .pred 	%p<2>;
    	.reg .f32 	%f<5>;
    	.reg .b32 	%r<5>;
    	.reg .b64 	%rd<13>;


    	ld.param.f32 	%f1, [saxpy_param_0];
    	ld.param.u64 	%rd2, [saxpy_param_1];
    	ld.param.u64 	%rd3, [saxpy_param_2];
    	ld.param.u64 	%rd4, [saxpy_param_3];
    	ld.param.u64 	%rd5, [saxpy_param_4];
    	mov.u32 	%r1, %ctaid.x;
    	mov.u32 	%r2, %ntid.x;
    	mov.u32 	%r3, %tid.x;
    	mad.lo.s32 	%r4, %r1, %r2, %r3;
    	cvt.u64.u32 	%rd1, %r4;
    	setp.ge.u64 	%p1, %rd1, %rd5;
    	@%p1 bra 	$L__BB0_2;

    	cvta.to.global.u64 	%rd6, %rd2;
    	shl.b64 	%rd7, %rd1, 2;
    	add.s64 	%rd8, %rd6, %rd7;
    	ld.global.f32 	%f2, [%rd8];
    	cvta.to.global.u64 	%rd9, %rd3;
    	add.s64 	%rd10, %rd9, %rd7;
    	ld.global.f32 	%f3, [%rd10];
    	fma.rn.ftz.f32 	%f4, %f2, %f1, %f3;
    	cvta.to.global.u64 	%rd11, %rd4;
    	add.s64 	%rd12, %rd11, %rd7;
    	st.global.f32 	[%rd12], %f4;

    $L__BB0_2:
    	ret;

    } |} ]

let%expect_test "SAXPY" =
  let _prog = Cudajit.compile_to_ptx ~cu_src:kernel ~name:"saxpy" ~options:["--use_fast_math"] ~with_debug:true in
	Cudajit.cu_init 0
	(* let _context = Cudajit.cu_ctx_create  *)