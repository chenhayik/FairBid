const assert = require("node:assert");
const test = require("node:test");
const {reviewRatingDelta} = require("./trust");

test("reviewRatingDelta: hiding a visible review removes its rating", () => {
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 4, hidden: false}, true), {sum: -4, count: -1});
  // `hidden` is absent on a review nobody has moderated yet.
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 5}, true), {sum: -5, count: -1});
});

test("reviewRatingDelta: hiding an already hidden review changes nothing", () => {
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 4, hidden: true}, true), {sum: 0, count: 0});
});

test("reviewRatingDelta: un-hiding a hidden review adds its rating back", () => {
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 3, hidden: true}, false), {sum: 3, count: 1});
});

test("reviewRatingDelta: keeping a visible review changes nothing", () => {
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 3, hidden: false}, false), {sum: 0, count: 0});
  assert.deepStrictEqual(
      reviewRatingDelta({rating: 3}, false), {sum: 0, count: 0});
});

test("reviewRatingDelta: hide then un-hide nets to zero", () => {
  const review = {rating: 2, hidden: false};
  const out = reviewRatingDelta(review, true);
  const back = reviewRatingDelta({...review, hidden: true}, false);
  assert.strictEqual(out.sum + back.sum, 0);
  assert.strictEqual(out.count + back.count, 0);
});
