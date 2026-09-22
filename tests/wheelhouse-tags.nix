{ platformTags }:
{
  testManylinux = {
    expr = platformTags { pythonVersion = "3.13"; platform = "x86_64-manylinux_2_28"; };
    expected = {
      python = "3.13";
      uvPythonVersion = "3.13";
      uvPythonPlatform = "x86_64-manylinux_2_28";
      pipPythonVersion = "313";
      pipPlatforms = [
        "manylinux_2_28_x86_64"
        "manylinux_2_27_x86_64"
        "manylinux_2_26_x86_64"
        "manylinux_2_25_x86_64"
        "manylinux_2_24_x86_64"
        "manylinux_2_23_x86_64"
        "manylinux_2_22_x86_64"
        "manylinux_2_21_x86_64"
        "manylinux_2_20_x86_64"
        "manylinux_2_19_x86_64"
        "manylinux_2_18_x86_64"
        "manylinux_2_17_x86_64"
        "manylinux_2_16_x86_64"
        "manylinux_2_15_x86_64"
        "manylinux_2_14_x86_64"
        "manylinux_2_13_x86_64"
        "manylinux_2_12_x86_64"
        "manylinux_2_11_x86_64"
        "manylinux_2_10_x86_64"
        "manylinux_2_9_x86_64"
        "manylinux_2_8_x86_64"
        "manylinux_2_7_x86_64"
        "manylinux_2_6_x86_64"
        "manylinux_2_5_x86_64"
        "manylinux2014_x86_64"
        "manylinux2010_x86_64"
        "manylinux1_x86_64"
        "linux_x86_64"
      ];
      pipAbi = "cp313";
      uvEnvironment = { };
      markerEnvironment = {
        implementation_name = "cpython";
        implementation_version = "3.13.0";
        os_name = "posix";
        platform_machine = "x86_64";
        platform_python_implementation = "CPython";
        platform_release = "";
        platform_system = "Linux";
        platform_version = "";
        python_full_version = "3.13.0";
        python_version = "3.13";
        sys_platform = "linux";
      };
    };
  };
  testDarwinAarch64 = {
    expr = platformTags { pythonVersion = "3.14"; platform = "aarch64-apple-darwin"; };
    expected = {
      python = "3.14";
      uvPythonVersion = "3.14";
      uvPythonPlatform = "aarch64-apple-darwin";
      pipPythonVersion = "314";
      pipPlatforms = [ "macosx_14_0_arm64" ];
      pipAbi = "cp314";
      uvEnvironment = { MACOSX_DEPLOYMENT_TARGET = "14.0"; };
      markerEnvironment = {
        implementation_name = "cpython";
        implementation_version = "3.14.0";
        os_name = "posix";
        platform_machine = "arm64";
        platform_python_implementation = "CPython";
        platform_release = "";
        platform_system = "Darwin";
        platform_version = "";
        python_full_version = "3.14.0";
        python_version = "3.14";
        sys_platform = "darwin";
      };
    };
  };
  testDarwinX8664 = {
    expr = (platformTags { pythonVersion = "3.13"; platform = "x86_64-apple-darwin"; }).pipPlatforms;
    expected = [ "macosx_14_0_x86_64" ];
  };
  testBadPythonVersion = {
    expr = builtins.tryEval (platformTags { pythonVersion = "three"; platform = "x86_64-linux"; });
    expected = { success = false; value = false; };
  };
  testBadPlatform = {
    expr = builtins.tryEval (platformTags { pythonVersion = "3.13"; platform = "x86_64 manylinux"; });
    expected = { success = false; value = false; };
  };
  testBadVendor = {
    expr = builtins.tryEval (platformTags { pythonVersion = "3.13"; platform = "x86_64-windows"; });
    expected = { success = false; value = false; };
  };
}
