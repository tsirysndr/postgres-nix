import { setup } from "fluentci:dependency/determinate-nix";

export const setupNix = args => () => {
  return setup(args);
};
