# gh (GitHub CLI). `enable` installs the package; `gitCredentialHelper`
# registers gh as git's credential helper for github.com and gist.github.com.
# This is the nix-native replacement for running `gh auth setup-git`, which
# used to write those helper lines into a hand-managed ~/.gitconfig that then
# shadowed this generation's ~/.config/git/config.
{
  enable = true;
  gitCredentialHelper.enable = true;
}
