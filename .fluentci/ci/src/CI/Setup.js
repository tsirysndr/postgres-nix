import { setup } from "fluentci:dependency/determinate-nix";

export const setupNix = args => () => {
  setup(args);
};
